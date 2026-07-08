defmodule RuleMaven.Workers.QuizWorker do
  @moduledoc """
  Durable generation of the multiple-choice rules quiz for a game. Persists
  the result to `quiz_<game_id>` and broadcasts `{:quiz_ready, entries}` on
  `topic/1`.

  Mirrors `DidYouKnowWorker`: `unique` per game, survives restarts, no-op in
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

  def topic(game_id), do: "quiz:#{game_id}"

  @doc "Enqueue quiz generation (no-op in test where Oban isn't supervised)."
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
      Jobs.start_run("quiz", {"game", game_id}, "Rules quiz — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Reading #{String.length(text)} chars of rulebook for quiz questions…")

    case RuleMaven.LLM.generate_quiz(game.name, text, game_id) do
      {:ok, entries} when entries != [] ->
        Settings.put("quiz_#{game_id}", Jason.encode!(entries))

        Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic(game_id), {:quiz_ready, entries})

        Jobs.finish_run(run, "done", "#{length(entries)} quiz questions.")
        :ok

      {:ok, []} ->
        Jobs.finish_run(run, "done", "No usable quiz questions.")
        :ok

      {:error, reason} ->
        Jobs.finish_run(run, "failed", inspect(reason))
        {:error, reason}
    end
  end

  defp oban_running?, do: Application.get_env(:rule_maven, Oban)[:testing] != :manual
end
