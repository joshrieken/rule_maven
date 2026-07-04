defmodule Mix.Tasks.RuleMaven.BackfillWeight do
  @shortdoc "Enqueue BGG re-enrich jobs to backfill complexity weight for existing games"
  @moduledoc """
  Enqueues a `RuleMaven.Workers.BggEnrichWorker` job for every game that has a
  `bgg_id` but no `weight` yet. Each job performs a genuine BGG API re-fetch
  (`RuleMaven.BGG.enrich_game(game, force: true)`), since the already-cached
  `bgg_data` for existing games predates requesting `stats=1` and so never
  contains an `averageweight` to reparse.

  This is a one-time manual admin task, not something scheduled or re-run
  automatically. Re-running it IS safe (the enrich job is idempotent and
  `unique` per game_id), but note it re-fetches and overwrites every BGG-
  sourced field on the game (players, playing time, image, etc.), not just
  weight — and a game BGG genuinely has no weight for will be re-enqueued
  and re-fetched on every subsequent run, since there's no way to distinguish
  "never checked" from "checked, BGG has none" without a schema change. Both
  are acceptable for an admin-triggered one-off; avoid adding this to a
  recurring job without addressing that.

      mix rule_maven.backfill_weight
  """

  use Mix.Task
  import Ecto.Query
  alias RuleMaven.{Repo, Workers.BggEnrichWorker}
  alias RuleMaven.Games.Game

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    games =
      Repo.all(
        from g in Game,
          where: is_nil(g.weight) and not is_nil(g.bgg_id)
      )

    if games == [] do
      Mix.shell().info("No games need weight backfill.")
    else
      Enum.each(games, fn game ->
        {:ok, _job} = %{game_id: game.id} |> BggEnrichWorker.new() |> Oban.insert()
      end)

      Mix.shell().info("Enqueued #{length(games)} BGG re-enrich job(s).")
    end
  end
end
