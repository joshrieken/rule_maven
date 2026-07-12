defmodule RuleMaven.Workers.VoiceWorker do
  @moduledoc """
  Durable, on-demand persona restyle. Generates (or reuses) a cached voice
  rendering of an answer and broadcasts `{:voice_ready, question_log_id, voice,
  content}` on `game:<id>` so the LiveView can swap it in.

  `unique` keyed on `(question_log_id, voice)` so two viewers asking for the same
  voice at once produce one job, not two LLM calls.
  """
  use Oban.Worker,
    queue: :llm_interactive,
    max_attempts: 3,
    unique: [
      keys: [:question_log_id, :voice],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Games, Jobs, Voices}

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: oban_id,
        args: %{"question_log_id" => ql_id, "voice" => voice, "game_id" => game_id} = args
      }) do
    # Tag this job's llm_logs rows with the question they serve (admin LLM
    # trace) — see RuleMaven.LLM.current_question_log_id/0.
    Logger.metadata(question_log_id: ql_id)

    ql = Games.get_question_log(ql_id)
    canonical = ql && (ql.canonical_answer || ql.answer)
    user_id = args["user_id"]

    cond do
      is_nil(ql) ->
        :ok

      # Never restyle a non-final answer: restyling the in-flight "Thinking..."
      # placeholder (or a blank row) yields a garbage stub that silently
      # replaces the answer. Silent skip — the restyle is re-enqueued once the
      # real answer lands. This is the durable guard behind the LiveView-side
      # skip.
      not final_answer?(canonical) ->
        :ok

      # A refused row will NEVER become restylable, so unlike the skip above
      # there is no later re-enqueue coming — tell any client that queued this
      # job, or its voice_pending entry (loader / sidebar dot) sticks forever.
      # The client falls back to the plain refusal text.
      ql.refused ->
        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          "game:#{game_id}",
          {:voice_failed, ql_id, voice}
        )

        :ok

      true ->
        do_restyle(ql, canonical, voice, game_id, oban_id, user_id)
    end
  end

  defp final_answer?(text) do
    t = text |> to_string() |> String.trim()
    t != "" and t != "Thinking..."
  end

  defp do_restyle(ql, canonical, voice, game_id, oban_id, user_id) do
    ql_id = ql.id
    game = Games.get_game!(game_id)

    run =
      Jobs.start_run("voice", {"question", ql_id}, "Voice “#{voice}” — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Restyling the answer in the “#{voice}” voice…")

    case Voices.restyle(ql_id, voice, canonical, game, user_id: user_id) do
      {:ok, content} ->
        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          "game:#{game_id}",
          {:voice_ready, ql_id, voice, content}
        )

        Jobs.finish_run(
          run,
          "done",
          "Restyled as “#{voice}” (#{String.length(content)} chars)."
        )

        :ok

      {:error, reason} ->
        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          "game:#{game_id}",
          {:voice_failed, ql_id, voice}
        )

        Jobs.finish_run(run, "failed", inspect(reason))
        {:error, reason}
    end
  end
end
