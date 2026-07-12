defmodule RuleMaven.Workers.ExpansionSyncWorker do
  @moduledoc """
  Durable BGG re-sync of a game's expansions. Throttled re-enrich of each
  expansion that has a BGG id, persisting `exp_sync:<game_id>` = "done/total" and
  broadcasting progress on `topic/1` so the index LiveView updates live and a
  remount can rediscover an in-flight sync.

  Replaces a detached `Task.start`: survives restarts (Oban re-runs the orphaned
  job) and `unique` prevents overlapping syncs for the same game.
  """
  use Oban.Worker,
    queue: :expansion,
    max_attempts: 3,
    unique: [
      keys: [:game_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RuleMaven.{Games, Jobs, Settings}

  def topic(game_id), do: "expansion_sync:#{game_id}"
  def key(game_id), do: "exp_sync:#{game_id}"

  @doc "Enqueue an expansion sync (no-op in test where Oban isn't supervised)."
  def enqueue(game_id) do
    if oban_running?() do
      %{game_id: game_id} |> new() |> Oban.insert()
    else
      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"game_id" => game_id}}) do
    case Games.get_game(game_id) do
      nil ->
        # Game deleted before the job ran — nothing to sync.
        :ok

      game ->
        sync_expansions(game, game_id, oban_id)
    end
  end

  defp sync_expansions(game, game_id, oban_id) do
    run =
      Jobs.start_run("expansion_sync", {"game", game_id}, "Expansion sync — #{game.name}",
        oban_job_id: oban_id
      )

    # Discover + link this game's expansions from BGG first, so freshly-linked
    # catalog rows are included in the detail refresh below. Use the cached BGG
    # XML when we have it (no API hit); otherwise fetch, which also links.
    if game.bgg_data do
      RuleMaven.BGG.relink_from_cache(game)
    else
      RuleMaven.BGG.enrich_game(game, force: true)
    end

    game = Games.get_game!(game_id)
    expansions = game |> Games.expansions_for() |> Enum.filter(& &1.bgg_id)
    total = length(expansions)
    counter = :counters.new(1, [:atomics])

    Jobs.event(run, "info", "Re-syncing #{total} expansions from BGG…")
    Settings.put(key(game_id), "0/#{total}")

    expansions
    |> Task.async_stream(
      fn exp ->
        :timer.sleep(1500)
        RuleMaven.BGG.enrich_game(exp, force: true)
        :counters.add(counter, 1, 1)
        done = :counters.get(counter, 1)
        Settings.put(key(game_id), "#{done}/#{total}")
        Jobs.event(run, "info", "Synced #{exp.name} · #{done}/#{total}")

        Phoenix.PubSub.broadcast(
          RuleMaven.PubSub,
          topic(game_id),
          {:expansion_progress, game_id, done, total}
        )
      end,
      max_concurrency: 2,
      ordered: false,
      timeout: 60_000,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Stream.run()

    Settings.delete(key(game_id))
    Jobs.finish_run(run, "done", "Synced #{total} expansions.")
    Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic(game_id), {:expansion_sync_done, game_id})
    :ok
  end

  defp oban_running?, do: Application.get_env(:rule_maven, Oban)[:testing] != :manual
end
