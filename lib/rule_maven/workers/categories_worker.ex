defmodule RuleMaven.Workers.CategoriesWorker do
  @moduledoc """
  Durable generation of suggested game categories. Persists to
  `categories_<game_id>` and broadcasts `{:categories_ready, cats}` on `topic/1`.
  Replaces a detached `Task.start`.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [keys: [:game_id], states: [:available, :scheduled, :executing, :retryable, :suspended]]

  alias RuleMaven.{Games, Settings}

  def topic(game_id), do: "categories:#{game_id}"

  @doc "Enqueue category generation (no-op in test where Oban isn't supervised)."
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

    case RuleMaven.LLM.generate_categories(game.name, text) do
      {:ok, cats} ->
        # When the game has no saved categories yet, there's nothing to blow away
        # — commit straight to the curated set (saves the admin a review click).
        # Once categories exist, a regeneration stays a draft so it doesn't nuke a
        # curated, embedding-anchored taxonomy without approval.
        if Games.list_game_categories(game) == [] do
          Games.replace_game_categories(game, cats)
          Settings.delete("categories_#{game_id}")
          saved = Games.list_game_categories(game)
          broadcast(game_id, {:categories_saved, saved})
        else
          Settings.put("categories_#{game_id}", Jason.encode!(cats))
          broadcast(game_id, {:categories_ready, cats})
        end

      {:error, _} ->
        broadcast(game_id, {:categories_ready, []})
    end

    :ok
  end

  defp broadcast(game_id, msg) do
    Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic(game_id), msg)
  end

  defp oban_running?, do: Application.get_env(:rule_maven, Oban)[:testing] != :manual
end
