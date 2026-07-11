defmodule RuleMaven.Workers.ExpansionDeltaWorker do
  @moduledoc """
  Durable expansion-delta generation. Runs the LLM extraction, writes the
  result into the `delta_*_<game_id>` Settings state machine, and broadcasts
  `{:delta_done, game_id}` on `ExpansionDelta.topic/1`.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [
      keys: [:game_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Games, Jobs, Settings, ExpansionDelta}

  def enqueue(game_id) do
    %{game_id: game_id} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"game_id" => game_id}}) do
    game = Games.get_game!(game_id)

    run =
      Jobs.start_run("expansion_delta", {"game", game_id}, "Expansion delta — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Extracting what this expansion changes…")

    result =
      try do
        ExpansionDelta.generate_content(game)
      rescue
        e -> {:error, "Unexpected error: #{Exception.message(e)}"}
      end

    case result do
      {:ok, json} ->
        Settings.put("delta_status_#{game_id}", "done")
        Settings.put("delta_content_#{game_id}", json)
        Jobs.finish_run(run, "done", "Delta generated (#{item_count(json)} items).")

      {:error, reason} ->
        Settings.put("delta_status_#{game_id}", "error")
        Settings.put("delta_error_#{game_id}", reason)
        Jobs.finish_run(run, "failed", reason)
    end

    Phoenix.PubSub.broadcast(
      RuleMaven.PubSub,
      ExpansionDelta.topic(game_id),
      {:delta_done, game_id}
    )

    :ok
  end

  defp item_count(json) do
    case Jason.decode(json) do
      {:ok, %{"components" => c, "setup" => s, "rules" => r}} ->
        length(c) + length(s) + length(r)

      _ ->
        0
    end
  end
end
