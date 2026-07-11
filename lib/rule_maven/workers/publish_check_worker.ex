defmodule RuleMaven.Workers.PublishCheckWorker do
  @moduledoc """
  Screens a GROUP question's scrubbed, normalized text (`cleaned_question`)
  before it may be listed on a public browse surface (the Unverified tab,
  community promotion).

  A group row is written `browsable: false` by AskWorker. This worker is the ONLY
  thing that flips it true, and it does so only on an unambiguous "no" from the
  publish-check prompt. Every other outcome — "yes", a malformed reply, an LLM
  error, a missing/nil `cleaned_question` — leaves the row unbrowsable.

  Failing closed means a worker outage degrades to "group questions don't get
  listed", never to "group questions get listed unchecked".

  `cleaned_question` is nil for `skip_normalize` ("Ask exactly this") rows —
  see `RuleMaven.LLM.ask/5` and `AskWorker` — so gate 3 (skip_normalize rows
  never publish) is enforced twice: once by the enqueue guard in AskWorker,
  and once here by the data itself (the `is_binary` guard below rejects nil
  before any LLM call is made).

  The row's ANSWER is unaffected: it is already `pooled` (if applicable) and
  already serves the cross-user cache, which never exposes the asker's wording
  or identity.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.{Jobs, LLM, Prompts, Repo}

  @doc """
  Queue the publish screen for a crew row.

  Skipped when no Oban instance is actually RUNNING — not when
  `config[:testing] == :manual`. That config value is set for the whole test env
  regardless of whether a given test starts its own named instance, so the
  config-keyed guard made this a no-op in EVERY test: the one seam the entire
  gate hangs from (a crew question can only ever become browsable through here)
  could have been deleted outright with the suite still green. Keyed on the live
  instance instead, a test that starts Oban exercises the real enqueue and one
  that doesn't still skips it.

  Note `Oban.Registry.whereis/1`, not `Process.whereis/1` — Oban registers
  through its own Registry, so the plain process lookup is always nil and would
  disable this call everywhere.
  """
  def enqueue(question_log_id) do
    if is_nil(Oban.Registry.whereis(Oban)) do
      :ok
    else
      %{question_log_id: question_log_id} |> new() |> Oban.insert()
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"question_log_id" => id}}) do
    case Repo.get(QuestionLog, id) do
      nil -> :ok
      ql -> screen(ql, oban_id)
    end
  end

  # Only a POOLED group row that is still unbrowsable and actually has cleaned
  # text is a candidate. Everything else is a no-op — including a non-group row,
  # which must never be touched by this worker; a skip_normalize row, whose
  # cleaned_question is nil; and an unpooled row (ungrounded citation), which
  # never surfaces cross-user and so must never be published or billed for.
  defp screen(
         %QuestionLog{group_id: gid, browsable: false, pooled: true, cleaned_question: cleaned} =
           ql,
         oban_id
       )
       when not is_nil(gid) and is_binary(cleaned) do
    cond do
      String.trim(cleaned) == "" ->
        :ok

      # Withdrawn while this job sat in the queue — don't pay for a screen whose
      # result the update guard would throw away anyway.
      not is_nil(ql.retracted_at) ->
        :ok

      # The normalize step FALLS BACK to the raw question on any failure — a 429,
      # a timeout, or a rewrite `accept_normalized?/2` rejects — and that fallback
      # is what lands in `cleaned_question` (see LLM.normalize_question/4). So an
      # unnormalized `cleaned_question` is not a scrub at all: it is the asker's
      # verbatim prose wearing the scrubbed column's name.
      #
      # Publishing it would defeat the whole gate, which rests on the premise that
      # what the screen cleared was the SCRUBBED text. Never publish text no
      # normalizer actually rewrote.
      #
      # This asks the ROW whether normalize ran. It used to compare `cleaned` to the
      # raw column — which never matched, because `strip_game_name/2` appends a "?"
      # to the stored text, so the fallback is the raw question plus a question mark.
      # The guard was dead code on the exact path it existed for.
      not ql.question_normalized ->
        :ok

      true ->
        decide(ql, cleaned, oban_id)
    end
  end

  defp screen(_ql, _oban_id), do: :ok

  defp decide(ql, cleaned, oban_id) do
    run =
      Jobs.start_run(
        "publish_check",
        {"question_log", ql.id},
        "Publish check — question ##{ql.id}",
        oban_job_id: oban_id
      )

    system = Prompts.template("publish_check_system")

    # `also_asked` is screened WITH the primary text, and one "yes" anywhere
    # withholds the whole row.
    #
    # The answer prompt asks the model for "the exact text of the additional
    # questions" when a message contains more than one — so `also_asked` is a
    # second copy of the asker's VERBATIM prose, living outside the
    # question/cleaned/canonical triad that every other gate mediates. Nothing
    # scrubbed it and nothing screened it, and the conversation renders it to
    # any reader of the row as "Related questions" chips. A crew question could
    # clear this screen on its sanitized primary text while shipping the raw
    # secondary one — names and all — straight to the public browse.
    prompt = Prompts.render("publish_check", %{question: screen_text(ql, cleaned)})

    # raw: true — chat/3 decodes a JSON "answer" key and returns "" otherwise, and
    # this prompt returns a bare word.
    result =
      LLM.chat(prompt, "publish_check",
        system: system,
        operation: "publish_check",
        question_log_id: ql.id,
        # Attributed to the asker so the call shows up in cost reporting. It is
        # the one recurring LLM charge this feature adds, and with a nil user_id
        # it was billed to nobody and invisible to every per-user cost view.
        # (It stays exempt from the ASK quota, which counts operation == "ask" —
        # the user didn't buy this call, we did.)
        user_id: ql.user_id,
        game_id: ql.game_id,
        raw: true
      )

    case result do
      {:ok, reply} ->
        maybe_publish(ql, reply, run)

      {:error, reason} ->
        Jobs.finish_run(
          run,
          "failed",
          "LLM error: #{inspect(reason)} — left unbrowsable, retrying."
        )

        {:error, reason}
    end
  end

  @doc """
  Everything on the row a reader could see, as one screened blob. The prompt asks
  "does it contain a person's name", so multiple questions concatenated still
  answer the question the screen is actually asking, and one "yes" anywhere
  withholds the whole row.

  Public so the gate's input can be asserted on directly: the bug this closes was
  that `also_asked` never reached the screen at all.
  """
  def screen_text(%QuestionLog{} = ql, cleaned) do
    # The ANSWER is screened too — it is the string that actually publishes.
    #
    # Screening only the question assumed the answer could not contain anything the
    # question didn't, which is false twice over: the ARGUMENT-SETTLING prompt rule
    # tells the model to name the disputing players, and `recent_context` feeds the
    # RAW prior turns of the thread into the answer prompt. So a perfectly scrubbed
    # question in turn 2 could still produce an answer carrying the name from
    # turn 1's unscrubbed ask — the row would clear the screen on its question and
    # publish an answer with "Dave" in it.
    answer = ql.canonical_answer || ql.answer
    # `followups` rides along too. It is model-authored rather than copied
    # verbatim, so it is a weaker leak than `also_asked` — but it is generated FROM
    # the crew's raw question in the same JSON response, it routinely echoes the
    # question's proper nouns, nothing scrubs it, and it renders in the same
    # "Related questions" box. Screening the row means screening every string on it
    # that a reader can see.
    extras =
      [ql.also_asked, ql.followups]
      |> Enum.flat_map(fn
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end)

    ([cleaned | extras] ++ [answer])
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(String.trim(&1) in ["", "Thinking..."]))
    |> Enum.join("\n")
  end

  # Fail closed: ONLY a bare "no" publishes. Anything else — "yes", a hedge, a
  # sentence, empty — leaves the row unbrowsable.
  defp maybe_publish(ql, reply, run) do
    normalized =
      reply |> to_string() |> String.trim() |> String.downcase() |> String.trim_trailing(".")

    if normalized == "no" do
      # A conditional UPDATE, not a changeset write on the row we loaded before a
      # multi-second LLM call. `retract_contributions/1` (contribute-off, group
      # delete, owner account deletion) can commit inside that window, and this is
      # the ONLY writer in the system that opens the gate — a stale write here
      # would re-publish a row the crew just explicitly withdrew.
      #
      # `pooled` is NOT a proxy for consent, which is what this guard used to
      # assume. AskWorker re-pools a row off a `never_pool` value it read minutes
      # earlier, so a retraction could land, be undone, and this worker would find
      # `pooled: true` sitting there and publish the text of a withdrawn question.
      # Consent is asked for directly now: the row's own retraction stamp, and the
      # group's live `contribute_to_community` flag joined in at update time.
      {published, _} =
        Repo.update_all(
          from(q in QuestionLog,
            join: g in RuleMaven.Groups.Group,
            on: g.id == q.group_id,
            where: q.id == ^ql.id,
            where: q.browsable == false,
            where: q.pooled == true,
            where: is_nil(q.retracted_at),
            where: g.contribute_to_community == true
          ),
          set: [browsable: true]
        )

      if published == 1 do
        Jobs.finish_run(run, "done", "Cleared — published.")
      else
        Jobs.finish_run(run, "done", "Cleared, but the row was withdrawn meanwhile — not published.")
      end
    else
      # A "yes" is not merely "don't list the question". It is the system PROVING
      # that the scrub failed: the screen looked at the text this row's answer was
      # generated from and found a person in it. Leaving `pooled` alone at that
      # exact moment was the one place the gate had hard evidence and ignored it.
      #
      # The answer is the artifact that actually leaves the crew — it feeds the
      # cross-user cache by design, on the premise that it carries no personal text.
      # That premise is exactly what a "yes" just falsified: the answer prompt's
      # ARGUMENT-SETTLING rule copies the disputing players' names into the answer
      # ("or the stated names"), so "Can Marcus's wizard counterspell mine?" comes
      # back as "Marcus's wizard can indeed…" and went on being served to strangers
      # as a cache hit while the question sat politely withheld.
      #
      # Un-pool it. The crew keeps its own answer — the `active_group_id` branch of
      # `find_pool_candidates/3` does not require `pooled` — so nothing is lost to
      # the people who asked; it just stops being everyone else's.
      {unpooled, _} =
        Repo.update_all(
          from(q in QuestionLog,
            where: q.id == ^ql.id,
            where: q.pooled == true,
            where: not is_nil(q.group_id)
          ),
          set: [pooled: false]
        )

      if unpooled == 1 do
        Jobs.finish_run(
          run,
          "done",
          "Not cleared — question withheld AND the answer pulled from the pool (it was written from text the screen just flagged)."
        )
      else
        Jobs.finish_run(run, "done", "Not cleared — left unbrowsable.")
      end
    end

    :ok
  end
end
