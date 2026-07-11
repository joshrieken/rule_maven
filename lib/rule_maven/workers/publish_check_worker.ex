defmodule RuleMaven.Workers.PublishCheckWorker do
  @moduledoc """
  Screens a GROUP question's scrubbed, normalized text (`cleaned_question`)
  before it may be listed on a public browse surface (the Unverified tab,
  community promotion).

  This worker is the GATE, not an audit. A crew row reaches it `browsable: false`
  AND `pooled: false`: AskWorker does not pool crew rows at all. Clearing the
  screen — an unambiguous "no" — is what sets BOTH flags, in one statement. Every
  other outcome leaves the row closed on both.

  That ordering is the whole point. It used to pool the answer inline and enqueue
  this check afterwards, i.e. pool first and revoke later, which meant the answer
  served every stranger during the queue hop and served them FOREVER if the check
  job was ever discarded (an LLM outage burns its 3 attempts and Oban drops it).
  The old promise — "a worker outage degrades to 'crew questions don't get listed',
  never to 'crew questions get listed unchecked'" — was true of `browsable` and
  false of `pooled`, and `pooled` is the artifact that actually leaves the crew.
  An outage now fails closed on both.

  A "yes" additionally PULLS an already-pooled row (a legacy row, or one pooled by
  an older path): a "yes" is positive evidence that the text this row's answer was
  written from names a real person. Only a bare "yes" does this — a hedge, a
  sentence or an empty reply proves nothing, and un-pooling is irreversible, so
  ambiguity withholds without destroying.

  The crew is never deprived of its own answer: the `active_group_id` branch of
  `find_pool_candidates/3` requires `citation_valid`, not `pooled`.

  `cleaned_question` is nil for `skip_normalize` ("Ask exactly this") rows — see
  `RuleMaven.LLM.ask/5` and `AskWorker` — so those rows never publish and never
  pool, enforced both by the enqueue guard and by the `is_binary` guard here.
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

  # A crew row that is NOT YET POOLED, still unbrowsable, carries a grounded
  # citation, and actually has cleaned text. Everything else is a no-op — including
  # a non-group row, which this worker must never touch; a skip_normalize row, whose
  # cleaned_question is nil; and an ungrounded-citation row, which is not fit to
  # serve anyone and must never be published or billed for.
  #
  # `pooled: false` in the head, not `true`. This worker is the GATE into the pool
  # for a crew row, not a post-hoc audit of a row already in it: AskWorker no longer
  # pools crew rows at all. If this job never runs, the answer never enters the
  # commons — which is what "fails closed" has to mean for the artifact that
  # actually leaves the crew.
  defp screen(
         %QuestionLog{
           group_id: gid,
           browsable: false,
           citation_valid: true,
           cleaned_question: cleaned
         } = ql,
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

    # LABELLED, not concatenated. The prompt is asked to distinguish a real person
    # from an in-game character, and a rules answer is wall-to-wall in-game proper
    # nouns ("Professor Plum", "the Vagabond"). Dumping an answer into a slot named
    # `Question:` invited the model to read every one of them as a person's name —
    # and the prompt's own tiebreak is "when uncertain, answer yes". Combined with a
    # "yes" now un-pooling the answer, that would have systematically destroyed the
    # crew contributions this feature exists to produce.
    question_block =
      [cleaned | extras]
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.join("\n")

    answer_block =
      if is_binary(answer) and String.trim(answer) not in ["", "Thinking..."],
        do: "\n\nANSWER:\n#{answer}",
        else: ""

    "QUESTION:\n#{question_block}#{answer_block}"
  end

  # Fail closed: ONLY a bare "no" publishes. Anything else — "yes", a hedge, a
  # sentence, empty — leaves the row unbrowsable.
  defp maybe_publish(ql, reply, run) do
    normalized =
      reply |> to_string() |> String.trim() |> String.downcase() |> String.trim_trailing(".")

    # Two decisions, two directions, and BOTH fail closed — which means they cannot
    # share a branch.
    #
    #   publish (open the gate)      : requires a bare "no".
    #   un-pool (destroy the answer) : requires a bare "yes".
    #
    # Un-pooling used to hang off the `else` of "is it 'no'?", i.e. it fired on a
    # hedge, a sentence, an empty string, "**no**", a stray leading newline — every
    # reply that proves NOTHING. Withholding on those is free and reversible;
    # un-pooling is neither. Nothing in the system ever re-pools an existing row
    # (`mark_pooled/1` only runs on the row AskWorker just answered), so one flaky
    # reply from the cheap model permanently evicted a perfectly good crew answer
    # from the commons — while the job log claimed the screen had "flagged" it.
    #
    # Ambiguity now means "leave it exactly as it was".
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
      # Clearing the screen is what puts the answer INTO the pool and the question
      # onto the browse — one statement, both flags, or neither.
      {published, _} =
        Repo.update_all(
          from(q in QuestionLog,
            join: g in RuleMaven.Groups.Group,
            on: g.id == q.group_id,
            where: q.id == ^ql.id,
            where: q.browsable == false,
            where: q.citation_valid == true,
            where: is_nil(q.retracted_at),
            where: g.contribute_to_community == true
          ),
          set: [browsable: true, pooled: true]
        )

      if published == 1 do
        Jobs.finish_run(run, "done", "Cleared — published.")
      else
        Jobs.finish_run(
          run,
          "done",
          "Cleared, but the row was withdrawn meanwhile — not published."
        )
      end
    else
      # An unambiguous "yes" is the system PROVING the scrub failed: the screen read
      # the text this row's answer was generated from and found a real person in it.
      # The answer is the artifact that actually leaves the crew — it feeds the
      # cross-user cache by design, on the premise that it carries no personal text,
      # and a "yes" is precisely the falsification of that premise. So pull it: the
      # crew keeps its own answer (the `active_group_id` branch of
      # `find_pool_candidates/3` does not require `pooled`), it just stops being
      # everyone else's.
      #
      # ONLY on a bare "yes". Anything else is withheld but left intact — see above.
      if normalized == "yes" do
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
            "Flagged — question withheld AND the answer pulled from the pool (it was written from text the screen flagged)."
          )
        else
          Jobs.finish_run(run, "done", "Flagged — left unbrowsable.")
        end
      else
        Jobs.finish_run(
          run,
          "done",
          "Unreadable reply (#{inspect(String.slice(normalized, 0, 40))}) — left unbrowsable, answer untouched."
        )
      end
    end

    :ok
  end
end
