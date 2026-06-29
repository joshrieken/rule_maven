defmodule RuleMaven.Workers.CheatSheetGenWorker do
  @moduledoc """
  Durable cheat-sheet generation. Runs the LLM compression + generation, writes
  the result into the `cheat_*_<game_id>` Settings state machine that the game
  form polls, and broadcasts `{:cheat_done, game_id}` on `topic/1` so the form
  can poll immediately.

  Replaces a detached `Task.start` in `CheatSheet.generate_async/4`: a server
  restart mid-generation no longer strands the job — Oban re-runs it. `unique`
  keeps one generation per game.
  """
  use Oban.Worker,
    queue: :cheatsheet,
    max_attempts: 3,
    unique: [keys: [:game_id], states: [:available, :scheduled, :executing, :retryable, :suspended]]

  alias RuleMaven.{Games, Jobs, Settings, CheatSheet}

  def topic(game_id), do: "cheat:#{game_id}"

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"game_id" => game_id} = args}) do
    game = Games.get_game!(game_id)
    level = Map.get(args, "level", "compact")
    expansion_ids = Map.get(args, "expansion_ids", [])
    started = CheatSheet.stored_started(game_id) || System.system_time(:second)

    run =
      Jobs.start_run("cheat_sheet", {"game", game_id}, "Cheat sheet — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Generating the #{level} cheat sheet#{if expansion_ids != [], do: " (+#{length(expansion_ids)} expansion(s))", else: ""}…")

    result =
      try do
        CheatSheet.generate_content(game, level, expansion_ids)
      rescue
        e -> {:error, "Unexpected error: #{Exception.message(e)}"}
      catch
        :exit, reason -> {:error, "Process exited: #{inspect(reason)}"}
      end

    elapsed = System.system_time(:second) - started

    # Don't overwrite if the user cancelled while we were generating.
    unless Settings.get("cheat_cancelled_#{game_id}") == "true" do
      case result do
        {:ok, content} ->
          Settings.put("cheat_status_#{game_id}", "done")
          Settings.put("cheat_content_#{game_id}", content)

        {:error, reason} ->
          Settings.put("cheat_status_#{game_id}", "error")
          Settings.put("cheat_error_#{game_id}", reason)
      end

      Settings.put("cheat_elapsed_#{game_id}", elapsed)
    end

    case result do
      {:ok, _} -> Jobs.finish_run(run, "done", "Generated in #{elapsed}s.")
      {:error, reason} -> Jobs.finish_run(run, "failed", reason)
    end

    Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic(game_id), {:cheat_done, game_id})
    :ok
  end
end
