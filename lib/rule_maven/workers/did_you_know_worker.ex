defmodule RuleMaven.Workers.DidYouKnowWorker do
  @moduledoc """
  Durable generation of "Did you know?" rule facts for a game. Persists the
  result to `did_you_know_<game_id>` and broadcasts `{:did_you_know_ready,
  facts}` on `topic/1` so a mounted show page swaps the raw-chunk fallback for
  clean, LLM-written facts live.

  Mirrors `SuggestionsWorker`: `unique` per game, survives restarts, no-op in
  test where Oban isn't supervised.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [keys: [:game_id], states: [:available, :scheduled, :executing, :retryable, :suspended]]

  alias RuleMaven.{Games, Settings}

  def topic(game_id), do: "did_you_know:#{game_id}"

  @doc "Enqueue fact generation (no-op in test where Oban isn't supervised)."
  def enqueue(game_id) do
    if oban_running?() do
      %{game_id: game_id} |> new() |> Oban.insert()
    else
      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"game_id" => game_id}}) do
    game = Games.get_game!(game_id)
    text = Games.document_full_text(game)

    case RuleMaven.LLM.generate_did_you_know(game.name, text) do
      {:ok, facts} when facts != [] ->
        Settings.put("did_you_know_#{game_id}", Jason.encode!(facts))

        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          topic(game_id),
          {:did_you_know_ready, facts}
        )

        :ok

      {:ok, []} ->
        # Nothing worth surfacing (thin rulebook); leave the chunk fallback in place.
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp oban_running?, do: Application.get_env(:rule_maven, Oban)[:testing] != :manual
end
