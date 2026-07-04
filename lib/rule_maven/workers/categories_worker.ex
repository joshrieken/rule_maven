defmodule RuleMaven.Workers.CategoriesWorker do
  @moduledoc """
  Durable generation of suggested game categories. Persists to
  `categories_<game_id>` and broadcasts `{:categories_ready, cats}` on `topic/1`.
  Replaces a detached `Task.start`.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [
      keys: [:game_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Games, Jobs, Settings}

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
  def perform(%Oban.Job{id: oban_id, args: %{"game_id" => game_id}}) do
    game = Games.get_game!(game_id)
    text = Games.document_full_text(game)

    run =
      Jobs.start_run("categories", {"game", game_id}, "Categories — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Reading #{String.length(text)} chars to derive rule categories…")

    case RuleMaven.LLM.generate_categories(game.name, text, game_id) do
      # Zero categories means the model produced nothing usable (empty or
      # unparseable output) — surface as a failure so the job log doesn't show
      # a green "done" run while the categories step stays pending.
      {:ok, []} ->
        broadcast(game_id, {:categories_ready, []})
        Jobs.finish_run(run, "failed", "Model returned no categories — retry Categories.")

      {:ok, cats} ->
        Jobs.event(run, :info, "Derived #{length(cats)} categories: #{category_names(cats)}")

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

        Jobs.finish_run(run, "done", "#{length(cats)} categories suggested.")

      {:error, reason} ->
        broadcast(game_id, {:categories_ready, []})
        Jobs.finish_run(run, "failed", inspect(reason))
    end

    :ok
  end

  defp broadcast(game_id, msg) do
    Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic(game_id), msg)
  end

  defp category_names([]), do: "—"
  defp category_names(cats), do: Enum.map_join(cats, ", ", & &1.name)

  defp oban_running?, do: Application.get_env(:rule_maven, Oban)[:testing] != :manual
end
