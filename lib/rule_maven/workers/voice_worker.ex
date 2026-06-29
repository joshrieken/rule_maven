defmodule RuleMaven.Workers.VoiceWorker do
  @moduledoc """
  Durable, on-demand persona restyle. Generates (or reuses) a cached voice
  rendering of an answer and broadcasts `{:voice_ready, question_log_id, voice,
  content}` on `game:<id>` so the LiveView can swap it in.

  `unique` keyed on `(question_log_id, voice)` so two viewers asking for the same
  voice at once produce one job, not two LLM calls.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [
      keys: [:question_log_id, :voice],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Games, Jobs, Voices}

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"question_log_id" => ql_id, "voice" => voice, "game_id" => game_id}}) do
    ql = Games.get_question_log(ql_id)

    if ql do
      game = Games.get_game!(game_id)
      canonical = ql.canonical_answer || ql.answer

      run =
        Jobs.start_run("voice", {"question", ql_id}, "Voice “#{voice}” — #{game.name}",
          oban_job_id: oban_id
        )

      Jobs.event(run, :info, "Restyling the answer in the “#{voice}” voice…")

      case Voices.restyle(ql_id, voice, canonical, game.name) do
        {:ok, content} ->
          Phoenix.PubSub.broadcast(
            RuleMaven.PubSub,
            "game:#{game_id}",
            {:voice_ready, ql_id, voice, content}
          )

          Jobs.finish_run(run, "done", "Restyled as “#{voice}”.")
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
    else
      :ok
    end
  end
end
