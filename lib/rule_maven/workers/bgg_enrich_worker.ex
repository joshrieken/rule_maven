defmodule RuleMaven.Workers.BggEnrichWorker do
  @moduledoc """
  Durable BoardGameGeek enrichment. Previously `enrich_game(force: true)` ran
  synchronously inside the LiveView `handle_info`, blocking the whole LiveView
  process during the (throttled, retry-prone) BGG API call. This moves it to an
  Oban job that survives restarts and broadcasts `{:bgg_enriched, game_id,
  :ok | {:error, reason}}` on `topic/1` so the page can refresh when it lands.
  """
  use Oban.Worker,
    queue: :expansion,
    max_attempts: 3,
    unique: [
      keys: [:game_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  import Ecto.Query
  alias RuleMaven.{BGG, Games, Jobs}
  alias RuleMaven.Workers.ThemePaletteWorker

  def topic(game_id), do: "bgg:#{game_id}"

  @doc """
  Game ids with a BGG enrich job currently in flight. Lets a LiveView re-seed
  its "pulling…" indicator after a remount so the spinner survives navigation.
  """
  def running_game_ids do
    RuleMaven.Repo.all(
      from j in Oban.Job,
        where:
          j.worker == "RuleMaven.Workers.BggEnrichWorker" and
            j.state in ["available", "scheduled", "executing", "retryable"],
        select: fragment("(?->>'game_id')::int", j.args)
    )
    |> MapSet.new()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{id: oban_id, args: %{"game_id" => game_id}}) do
    game = Games.get_game!(game_id)

    run =
      Jobs.start_run("bgg_enrich", {"game", game_id}, "BGG enrich — #{game.name}",
        oban_job_id: oban_id
      )

    Jobs.event(run, :info, "Fetching game details from BoardGameGeek…")

    status = enrich(game)
    finish(run, status)

    # Collapse the success payload (changed fields) back to :ok for subscribers.
    status = with {:ok, _} <- status, do: :ok

    Phoenix.PubSub.broadcast(RuleMaven.PubSub, topic(game_id), {:bgg_enriched, game_id, status})

    case status do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp enrich(game) do
    case BGG.enrich_game(game, force: true) do
      {:ok, updated} ->
        maybe_enqueue_palette(updated)
        {:ok, changed_fields(game, updated)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Theme palette is derivable from the BGG cover image alone, so kick it
  # off right away rather than waiting for the full rulebook pipeline.
  # `enqueue/1` itself no-ops for expansions (they inherit the base
  # game's palette) and only a first-time pull needs a fresh generate.
  # Oban isn't supervised in test (config :rule_maven, Oban, testing:
  # :manual), so skip there rather than crash on the unconfigured insert.
  defp maybe_enqueue_palette(updated) do
    if is_nil(updated.theme_palette) and
         Application.get_env(:rule_maven, Oban)[:testing] != :manual do
      ThemePaletteWorker.enqueue(updated)
    end
  end

  defp finish(run, {:ok, []}),
    do: Jobs.finish_run(run, "done", "Enriched from BGG — no field changes.")

  defp finish(run, {:ok, fields}),
    do: Jobs.finish_run(run, "done", "Enriched from BGG — updated #{Enum.join(fields, ", ")}.")

  defp finish(run, {:error, reason}), do: Jobs.finish_run(run, "failed", inspect(reason))

  # Names of the BGG-sourced fields whose value actually changed, for the job
  # summary (so the log says what the enrich did, not just that it ran).
  @tracked_fields ~w(image_url year_published min_players max_players playing_time bgg_rank category weight)a
  defp changed_fields(before, after_) do
    Enum.filter(@tracked_fields, fn f ->
      Map.get(before, f) != Map.get(after_, f)
    end)
    |> Enum.map(&to_string/1)
  end
end
