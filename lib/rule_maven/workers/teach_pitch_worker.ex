defmodule RuleMaven.Workers.TeachPitchWorker do
  @moduledoc """
  Durable generation of the "teach it in 60 seconds" summary for a game —
  four quick lines (goal / loop / win / trap) a player can read aloud to teach
  the table fast. Persists the result to `teach_pitch_<game_id>` and broadcasts
  `{:teach_pitch_ready, pitch}` on `topic/1`.

  Mirrors `CommonMistakesWorker`: `unique` per game, survives restarts, no-op in
  test where Oban isn't supervised.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [
      keys: [:game_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Games, Jobs, Settings}

  def topic(game_id), do: "teach_pitch:#{game_id}"

  @doc "Enqueue generation (no-op in test where Oban isn't supervised)."
  def enqueue(game_id) do
    if oban_running?() do
      %{game_id: game_id} |> new() |> Oban.insert()
    else
      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"game_id" => game_id}}) do
    game = Games.get_game!(game_id)
    text = Games.document_full_text(game)

    run =
      Jobs.start_run("teach_pitch", {"game", game_id}, "60-second teach — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(
      run,
      :info,
      "Reading #{String.length(text)} chars of rulebook for the quick teach…"
    )

    case RuleMaven.LLM.generate_teach_pitch(game.name, text, game_id) do
      {:ok, pitch} when map_size(pitch) > 0 ->
        Settings.put("teach_pitch_#{game_id}", Jason.encode!(pitch))

        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          topic(game_id),
          {:teach_pitch_ready, pitch}
        )

        Jobs.finish_run(run, "done", "#{map_size(pitch)} of 4 lines filled.")
        :ok

      {:ok, _empty} ->
        Jobs.finish_run(run, "done", "No teach worth surfacing (thin rulebook).")
        :ok

      {:error, reason} ->
        Jobs.finish_run(run, "failed", inspect(reason))
        {:error, reason}
    end
  end

  defp oban_running?, do: Application.get_env(:rule_maven, Oban)[:testing] != :manual
end
