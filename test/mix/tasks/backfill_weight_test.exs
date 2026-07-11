defmodule Mix.Tasks.RuleMaven.BackfillWeightTest do
  use RuleMaven.DataCase
  use Oban.Testing, repo: RuleMaven.Repo

  alias RuleMaven.Games
  alias RuleMaven.Workers.BggEnrichWorker

  # Oban isn't supervised in test (config :rule_maven, Oban, testing: :manual),
  # but the Mix task's `Oban.insert/1` needs a named, configured instance to
  # insert against. Start a queueless/pluginless one under the default name so
  # the plain (unnamed) insert call resolves for real.
  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  test "enqueues a BggEnrichWorker job for games with a bgg_id but no weight yet" do
    {:ok, needs_backfill} =
      Games.create_game(%{name: "Needs Backfill", bgg_id: 1})

    {:ok, already_set} =
      Games.create_game(%{name: "Already Set", bgg_id: 2, weight: 1.0})

    {:ok, no_bgg_id} = Games.create_game(%{name: "No BGG Id"})

    Mix.Tasks.RuleMaven.BackfillWeight.run([])

    assert_enqueued(worker: BggEnrichWorker, args: %{game_id: needs_backfill.id})
    refute_enqueued(worker: BggEnrichWorker, args: %{game_id: already_set.id})
    refute_enqueued(worker: BggEnrichWorker, args: %{game_id: no_bgg_id.id})
  end
end
