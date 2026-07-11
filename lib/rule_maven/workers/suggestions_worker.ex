defmodule RuleMaven.Workers.SuggestionsWorker do
  @moduledoc """
  Durable generation of suggested rules questions for a game. Persists the
  result to `suggestions_<game_id>` and broadcasts `{:suggestions_ready, qs}` on
  `topic/1` so any mounted LiveView (game form or show) updates live.

  Replaces a detached `Task.start`: survives server restarts (Oban re-runs an
  orphaned job) and `unique` keeps one job per game.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [
      keys: [:game_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Games, Jobs, Settings}
  alias RuleMaven.Games.QuestionLog

  def topic(game_id), do: "suggestions:#{game_id}"

  @doc "Enqueue suggestion generation (no-op in test where Oban isn't supervised)."
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
      Jobs.start_run("suggestions", {"game", game_id}, "Suggested questions — #{game.name}",
        oban_job_id: oban_id
      )

    # This list is handed to a PUBLIC-output LLM call (the suggestions are shown
    # to every visitor), so it must never carry a group asker's wording: drop
    # group rows that haven't cleared the publish check, and use the scrubbed
    # display text rather than the raw `question` column for everything else.
    already_asked =
      game
      |> Games.recent_questions(100)
      |> Enum.reject(&(&1.group_id && not &1.browsable))
      |> Enum.map(&QuestionLog.display_question/1)
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    Jobs.event(
      run,
      :info,
      "Reading #{String.length(text)} chars of rulebook, avoiding #{length(already_asked)} already-asked questions…"
    )

    case RuleMaven.LLM.suggest_questions(game.name, text, already_asked) do
      # Zero suggestions = nothing usable from the model. Don't persist "[]" —
      # the readiness step reads presence of the setting as done, which would
      # mark the step complete with an empty suggestion list.
      {:ok, []} ->
        Jobs.finish_run(run, "failed", "Model returned no suggestions — retry.")
        :ok

      {:ok, qs} ->
        Settings.put("suggestions_#{game_id}", Jason.encode!(qs))
        Jobs.finish_run(run, "done", "#{length(qs)} suggestions.")
        Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic(game_id), {:suggestions_ready, qs})
        :ok

      {:error, reason} ->
        Jobs.finish_run(run, "failed", reason)
        {:error, reason}
    end
  end

  defp oban_running?, do: Application.get_env(:rule_maven, Oban)[:testing] != :manual
end
