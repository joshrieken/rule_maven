defmodule RuleMaven.Workers.FirstPlayerWorker do
  @moduledoc """
  Durable generation of themed "who goes first" selectors for a game. Persists
  the result to `first_player_<game_id>` and broadcasts
  `{:first_player_ready, selectors}` on `topic/1` so a mounted show page can
  reveal the picker live.

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

  def topic(game_id), do: "first_player:#{game_id}"

  @doc "Enqueue selector generation (no-op in test where Oban isn't supervised)."
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
      Jobs.start_run(
        "first_player",
        {"game", game_id},
        "First-player selectors — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(
      run,
      :info,
      "Reading #{String.length(text)} chars of rulebook for first-player selectors…"
    )

    case RuleMaven.LLM.generate_first_player(game.name, text, game_id) do
      {:ok, selectors} when selectors != [] ->
        Settings.put("first_player_#{game_id}", Jason.encode!(selectors))

        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          topic(game_id),
          {:first_player_ready, selectors}
        )

        Jobs.finish_run(run, "done", "#{length(selectors)} selectors.")
        :ok

      {:ok, []} ->
        Jobs.finish_run(run, "done", "No selectors worth surfacing.")
        :ok

      {:error, reason} ->
        Jobs.finish_run(run, "failed", inspect(reason))
        {:error, reason}
    end
  end

  defp oban_running?, do: Application.get_env(:rule_maven, Oban)[:testing] != :manual
end
