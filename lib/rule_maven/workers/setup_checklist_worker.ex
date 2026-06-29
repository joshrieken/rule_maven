defmodule RuleMaven.Workers.SetupChecklistWorker do
  @moduledoc """
  Durable setup-checklist generation. Runs the LLM extraction, writes the result
  into the `setup_*_<game_id>` Settings state machine the show page reads, and
  broadcasts `{:setup_done, game_id}` on `Setup.topic/1`.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [keys: [:game_id], states: [:available, :scheduled, :executing, :retryable, :suspended]]

  alias RuleMaven.{Games, Jobs, Settings, Setup}

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"game_id" => game_id}}) do
    game = Games.get_game!(game_id)

    run =
      Jobs.start_run("setup_checklist", {"game", game_id}, "Setup checklist — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Asking the model to build the setup checklist…")

    result =
      try do
        Setup.generate_content(game)
      rescue
        e -> {:error, "Unexpected error: #{Exception.message(e)}"}
      end

    case result do
      {:ok, json} ->
        Settings.put("setup_status_#{game_id}", "done")
        Settings.put("setup_content_#{game_id}", json)
        Jobs.finish_run(run, "done", "Checklist generated.")

      {:error, reason} ->
        Settings.put("setup_status_#{game_id}", "error")
        Settings.put("setup_error_#{game_id}", reason)
        Jobs.finish_run(run, "failed", reason)
    end

    Phoenix.PubSub.broadcast(RuleMaven.PubSub, Setup.topic(game_id), {:setup_done, game_id})
    :ok
  end
end
