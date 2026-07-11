defmodule RuleMaven.Workers.ThemePaletteWorkerTest do
  use RuleMaven.DataCase

  alias RuleMaven.Games
  alias RuleMaven.Workers.ThemePaletteWorker

  # Oban isn't supervised in test (config :rule_maven, Oban, testing: :manual),
  # but `enqueue/1`'s `Oban.insert/1` needs a named, configured instance to
  # insert against. Start a queueless/pluginless one under the default name so
  # the plain (unnamed) insert calls in the worker resolve for real.
  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp job_count(game_id) do
    import Ecto.Query

    RuleMaven.Repo.aggregate(
      from(j in Oban.Job,
        where: j.worker == "RuleMaven.Workers.ThemePaletteWorker",
        where: fragment("?->>'game_id' = ?", j.args, ^to_string(game_id))
      ),
      :count
    )
  end

  describe "enqueue/1" do
    test "enqueues for a base game with a cover image" do
      {:ok, game} = Games.create_game(%{name: "TP Base", image_url: "https://example.com/a.jpg"})

      assert {:ok, %Oban.Job{}} = ThemePaletteWorker.enqueue(game)
      assert job_count(game.id) == 1
    end

    test "is a no-op for an expansion — it inherits the base game's palette instead" do
      {:ok, base} = Games.create_game(%{name: "TP Base 2"})
      {:ok, exp} = Games.create_game(%{name: "TP Exp", image_url: "https://example.com/b.jpg"})
      :ok = Games.link_expansion(exp.id, base.id)

      assert {:ok, :expansion_inherits} = ThemePaletteWorker.enqueue(exp)
      assert job_count(exp.id) == 0
    end

    test "skips a game without a cover image" do
      {:ok, game} = Games.create_game(%{name: "TP No Image"})
      assert {:ok, :no_image} = ThemePaletteWorker.enqueue(game)
    end
  end
end
