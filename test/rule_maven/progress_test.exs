defmodule RuleMaven.ProgressTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.Progress
  alias RuleMaven.Progress.GameMastery
  alias RuleMaven.Repo
  alias RuleMaven.Users.User
  alias RuleMaven.Voices.GameVoice

  import RuleMaven.GamesFixtures

  defp user_fixture(name) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "prog_#{name}_#{System.unique_integer([:positive])}",
        email: "prog_#{name}_#{System.unique_integer([:positive])}@test.com",
        password: "password1234"
      })

    user
  end

  defp voice_fixture(game, slug, unlock_level) do
    {:ok, gv} =
      %GameVoice{}
      |> Ecto.Changeset.change(%{
        game_id: game.id,
        slug: slug,
        label: slug,
        emoji: "🎩",
        style: "some style",
        unlock_level: unlock_level
      })
      |> Repo.insert()

    gv
  end

  describe "level_for/1 and thresholds" do
    test "level boundaries follow 25·n·(n+1)" do
      assert Progress.threshold(1) == 50
      assert Progress.threshold(2) == 150
      assert Progress.threshold(3) == 300

      assert Progress.level_for(0) == 0
      assert Progress.level_for(49) == 0
      assert Progress.level_for(50) == 1
      assert Progress.level_for(149) == 1
      assert Progress.level_for(150) == 2
      assert Progress.level_for(300) == 3
    end

    test "level_progress reports fill within the current level" do
      assert %{level: 0, into: 30, span: 50} = Progress.level_progress(30)
      assert %{level: 1, into: 10, span: 100} = Progress.level_progress(60)
    end
  end

  describe "award_ask/3 — earning" do
    setup do
      %{user: user_fixture("u"), game: game_fixture()}
    end

    test "first award grants XP globally and per-game", %{user: user, game: game} do
      assert {:awarded, result} = Progress.award_ask(user.id, game.id, "src-1")
      assert result.xp_delta == 15
      assert result.game_mastery.xp == 15
      assert Repo.get(User, user.id).curator_points == 1
    end

    test "a different source_key stacks XP", %{user: user, game: game} do
      assert {:awarded, _} = Progress.award_ask(user.id, game.id, "src-1")
      assert {:awarded, result} = Progress.award_ask(user.id, game.id, "src-2")
      assert result.game_mastery.xp == 30
      assert Repo.get(User, user.id).curator_points == 2
    end

    test "same user re-asking the same source_key awards nothing", %{user: user, game: game} do
      assert {:awarded, _} = Progress.award_ask(user.id, game.id, "src-1")
      assert {:duplicate, mastery} = Progress.award_ask(user.id, game.id, "src-1")
      assert mastery.xp == 15
      assert Repo.get(User, user.id).curator_points == 1
    end

    test "a cache hit new to a DIFFERENT user still awards", %{user: user_a, game: game} do
      user_b = user_fixture("b")
      assert {:awarded, _} = Progress.award_ask(user_a.id, game.id, "shared-canonical")
      assert {:awarded, result} = Progress.award_ask(user_b.id, game.id, "shared-canonical")
      assert result.game_mastery.xp == 15
    end
  end

  describe "award_ask/3 — leveling and unlocks" do
    setup do
      game = game_fixture()
      user = user_fixture("lvl")
      voice_fixture(game, "merchant", 1)
      voice_fixture(game, "banker", 3)
      voice_fixture(game, "always-open", 0)
      %{user: user, game: game}
    end

    test "crossing a level flips level_up and grants the level's persona", ctx do
      %{user: user, game: game} = ctx

      # 4 asks × 15 = 60 XP → crosses Lv1 (@50). The 4th award is the crossing.
      results =
        for n <- 1..4 do
          {:awarded, r} = Progress.award_ask(user.id, game.id, "s#{n}")
          r
        end

      crossing = List.last(results)
      assert crossing.game_mastery.level == 1
      assert crossing.level_up
      assert "merchant" in crossing.unlocked
      refute "banker" in crossing.unlocked

      mastery = Progress.get_mastery(user.id, game.id)
      assert "merchant" in mastery.unlocked_voice_slugs
      # unlock_level 0 personas are never "unlocked" — they were always open.
      refute "always-open" in mastery.unlocked_voice_slugs
    end

    test "non-crossing awards report level_up: false", ctx do
      %{user: user, game: game} = ctx
      {:awarded, r} = Progress.award_ask(user.id, game.id, "only-one")
      refute r.level_up
      assert r.unlocked == []
    end
  end

  describe "the :mastery_levels flag" do
    setup do
      game = game_fixture()
      user = user_fixture("flag")
      voice_fixture(game, "merchant", 1)
      # Flag rows are written through the Repo, so the sandbox rolls the gate
      # back for us at the end of each test — no manual restore needed.
      {:ok, _} = RuleMaven.Flags.disable(:mastery_levels)
      %{user: user, game: game}
    end

    test "with the flag off, XP is banked instead of applied", %{user: user, game: game} do
      assert {:deferred, mastery} = Progress.award_ask(user.id, game.id, "off-1")
      assert mastery.xp == 0
      assert Repo.get(User, user.id).curator_points == 0
      assert Progress.pending_count() == 1
    end

    test "the dedupe still holds while banked", %{user: user, game: game} do
      assert {:deferred, _} = Progress.award_ask(user.id, game.id, "off-1")
      assert {:duplicate, _} = Progress.award_ask(user.id, game.id, "off-1")
      assert Progress.pending_count() == 1
    end

    test "turning it back on levels the user up for the meantime", %{user: user, game: game} do
      for n <- 1..4, do: {:deferred, _} = Progress.award_ask(user.id, game.id, "off-#{n}")

      {:ok, _} = RuleMaven.Flags.enable(:mastery_levels)
      assert %{users: 1, events: 4} = Progress.backfill_pending()

      mastery = Progress.get_mastery(user.id, game.id)
      # 4 × 15 = 60 XP → Lv1 (@50), and the level's persona comes with it.
      assert mastery.xp == 60
      assert mastery.level == 1
      assert "merchant" in mastery.unlocked_voice_slugs
      # One curator point per banked event, same as if they had been live.
      assert Repo.get(User, user.id).curator_points == 4
      assert Progress.pending_count() == 0
    end

    test "the backfill is idempotent", %{user: user, game: game} do
      {:deferred, _} = Progress.award_ask(user.id, game.id, "off-1")
      {:ok, _} = RuleMaven.Flags.enable(:mastery_levels)

      assert %{events: 1} = Progress.backfill_pending()
      assert %{users: 0, events: 0} = Progress.backfill_pending()
      assert Progress.get_mastery(user.id, game.id).xp == 15
      assert Repo.get(User, user.id).curator_points == 1
    end

    test "users still outside the gate keep their XP banked", %{user: user, game: game} do
      {:deferred, _} = Progress.award_ask(user.id, game.id, "off-1")

      assert %{users: 0, events: 0} = Progress.backfill_pending()
      assert Progress.pending_count() == 1
      assert Progress.get_mastery(user.id, game.id).xp == 0
    end

    test "an actor grant lets one user through ahead of the boolean", %{user: user, game: game} do
      {:deferred, _} = Progress.award_ask(user.id, game.id, "off-1")
      RuleMaven.Flags.grant_actor(:mastery_levels, user)

      assert %{users: 1, events: 1} = Progress.backfill_pending()
      assert Progress.get_mastery(user.id, game.id).xp == 15
    end
  end

  describe "get_mastery/2" do
    test "returns a zeroed virtual struct when none exists" do
      user = user_fixture("empty")
      game = game_fixture()

      assert %GameMastery{xp: 0, level: 0, unlocked_voice_slugs: []} =
               Progress.get_mastery(user.id, game.id)
    end
  end
end
