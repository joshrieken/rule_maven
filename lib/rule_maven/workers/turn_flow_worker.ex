defmodule RuleMaven.Workers.TurnFlowWorker do
  @moduledoc """
  Durable generation of the turn structure for a game's "what can I do now?"
  wizard — ordered phases and the actions available in each. Persists the result
  to `turn_flow_<game_id>` and broadcasts `{:turn_flow_ready, phases}` on
  `topic/1`. An empty result (turn too freeform/thin to map) leaves nothing
  stored, so the wizard card stays hidden.

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

  def topic(game_id), do: "turn_flow:#{game_id}"

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
      Jobs.start_run("turn_flow", {"game", game_id}, "Turn wizard — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Reading #{String.length(text)} chars to map the turn structure…")

    case RuleMaven.LLM.generate_turn_flow(game.name, text, game_id) do
      {:ok, phases} when phases != [] ->
        Settings.put("turn_flow_#{game_id}", Jason.encode!(phases))

        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          topic(game_id),
          {:turn_flow_ready, phases}
        )

        actions = Enum.reduce(phases, 0, fn p, acc -> acc + length(p["actions"] || []) end)
        Jobs.finish_run(run, "done", "#{length(phases)} phases, #{actions} actions.")
        :ok

      {:ok, []} ->
        Jobs.finish_run(run, "done", "Turn too freeform/thin to map — no wizard.")
        :ok

      {:error, reason} ->
        Jobs.finish_run(run, "failed", inspect(reason))
        {:error, reason}
    end
  end

  defp oban_running?, do: Application.get_env(:rule_maven, Oban)[:testing] != :manual
end
