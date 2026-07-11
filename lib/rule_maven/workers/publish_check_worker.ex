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
    if String.trim(cleaned) == "" do
      :ok
    else
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
    prompt = Prompts.render("publish_check", %{question: cleaned})

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

  # Fail closed: ONLY a bare "no" publishes. Anything else — "yes", a hedge, a
  # sentence, empty — leaves the row unbrowsable.
  defp maybe_publish(ql, reply, run) do
    normalized =
      reply |> to_string() |> String.trim() |> String.downcase() |> String.trim_trailing(".")

    if normalized == "no" do
      case ql |> QuestionLog.changeset(%{browsable: true}) |> Repo.update() do
        {:ok, _} ->
          Jobs.finish_run(run, "done", "Cleared — published.")

        {:error, _cs} ->
          Jobs.finish_run(run, "failed", "Couldn't save browsable flag — left unbrowsable.")
      end
    else
      Jobs.finish_run(run, "done", "Not cleared — left unbrowsable.")
    end

    :ok
  end
end
