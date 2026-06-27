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

  import Ecto.Query
  alias RuleMaven.{Games, Settings}

  @worker "RuleMaven.Workers.DidYouKnowWorker"
  @active_states ~w(available scheduled executing retryable suspended)

  def topic(game_id), do: "did_you_know:#{game_id}"

  @doc "True when fact generation for this game is queued or running (survives a refresh)."
  def running?(game_id) do
    RuleMaven.Repo.exists?(
      from j in Oban.Job,
        where:
          j.worker == ^@worker and j.state in ^@active_states and
            fragment("?->>'game_id' = ?", j.args, ^to_string(game_id))
    )
  end

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
