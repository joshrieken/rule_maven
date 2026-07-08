defmodule RuleMaven.Workers.CommonMistakesWorker do
  @moduledoc """
  Durable generation of the "rules most tables get wrong" list for a game.
  Feeds the game's community questions in as confusion signals, persists the
  result to `common_mistakes_<game_id>` and broadcasts
  `{:common_mistakes_ready, entries}` on `topic/1`.

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
  alias RuleMaven.Games.QuestionLog

  def topic(game_id), do: "common_mistakes:#{game_id}"

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

    questions =
      game
      |> Games.faq_questions(15)
      |> Enum.map(&QuestionLog.display_question/1)

    run =
      Jobs.start_run(
        "common_mistakes",
        {"game", game_id},
        "Common mistakes — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(
      run,
      :info,
      "Reading #{String.length(text)} chars of rulebook + #{length(questions)} community questions…"
    )

    case RuleMaven.LLM.generate_common_mistakes(game.name, text, questions, game_id) do
      {:ok, entries} when entries != [] ->
        Settings.put("common_mistakes_#{game_id}", Jason.encode!(entries))

        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          topic(game_id),
          {:common_mistakes_ready, entries}
        )

        Jobs.finish_run(run, "done", "#{length(entries)} entries survived fact-check.")
        :ok

      {:ok, []} ->
        Jobs.finish_run(run, "done", "No entries survived fact-check.")
        :ok

      {:error, reason} ->
        Jobs.finish_run(run, "failed", inspect(reason))
        {:error, reason}
    end
  end

  defp oban_running?, do: Application.get_env(:rule_maven, Oban)[:testing] != :manual
end
