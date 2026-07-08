defmodule RuleMaven.Workers.ScoreCategoriesWorker do
  @moduledoc """
  Durable generation of the end-game scoring categories for a game's score pad.
  Persists the result to `score_categories_<game_id>` and broadcasts
  `{:score_categories_ready, categories}` on `topic/1`. An empty list (the game
  isn't decided by adding up points) is still persisted, as `[]`: the score-pad
  card reads it as "nothing to total" and stays hidden, while readiness reads
  the key's presence as a finished step. Storing nothing instead would leave
  the Score pad step Pending forever on every co-op game, and re-run the
  generation on each "Prepare game".

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

  def topic(game_id), do: "score_categories:#{game_id}"

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
      Jobs.start_run("score_categories", {"game", game_id}, "Score pad — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Reading #{String.length(text)} chars for scoring categories…")

    case RuleMaven.LLM.generate_score_categories(game.name, text, game_id) do
      {:ok, cats} when cats != [] ->
        Settings.put("score_categories_#{game_id}", Jason.encode!(cats))

        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          topic(game_id),
          {:score_categories_ready, cats}
        )

        Jobs.finish_run(run, "done", "#{length(cats)} scoring categories.")
        :ok

      {:ok, []} ->
        Settings.put("score_categories_#{game_id}", "[]")
        Jobs.finish_run(run, "done", "Not a points game — no score pad.")
        :ok

      {:error, reason} ->
        Jobs.finish_run(run, "failed", inspect(reason))
        {:error, reason}
    end
  end

  defp oban_running?, do: Application.get_env(:rule_maven, Oban)[:testing] != :manual
end
