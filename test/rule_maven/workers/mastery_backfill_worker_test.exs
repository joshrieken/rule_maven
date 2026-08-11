defmodule RuleMaven.Workers.MasteryBackfillWorkerTest do
  use RuleMaven.DataCase, async: true
  use Oban.Testing, repo: RuleMaven.Repo

  import RuleMaven.GamesFixtures

  alias RuleMaven.Progress
  alias RuleMaven.Workers.MasteryBackfillWorker

  defp user_fixture do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "mbw_#{System.unique_integer([:positive])}",
        email: "mbw_#{System.unique_integer([:positive])}@test.com",
        password: "password1234"
      })

    user
  end

  test "applies XP banked while the flag was off" do
    user = user_fixture()
    game = game_fixture()

    {:ok, _} = RuleMaven.Flags.disable(:mastery_levels)
    {:deferred, _} = Progress.award_ask(user.id, game.id, "banked-1")
    {:deferred, _} = Progress.award_ask(user.id, game.id, "banked-2")
    {:ok, _} = RuleMaven.Flags.enable(:mastery_levels)

    assert :ok = perform_job(MasteryBackfillWorker, %{})

    assert Progress.get_mastery(user.id, game.id).xp == 30
    assert Progress.pending_count() == 0
  end

  test "is a no-op when nothing is banked" do
    assert :ok = perform_job(MasteryBackfillWorker, %{})
  end
end
