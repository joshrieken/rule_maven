defmodule RuleMaven.Games.CurationTest do
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.Curation
  alias RuleMaven.Repo
  alias RuleMaven.Users

  defp user_fixture(name) do
    {:ok, u} =
      Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "testpass1234"
      })

    u
  end

  defp log(game, author, attrs \\ %{}) do
    {:ok, q} =
      Games.log_question(
        Map.merge(
          %{
            game_id: game.id,
            question: "How does X work?",
            answer: "It works like Y.",
            user_id: author && author.id,
            pooled: true,
            browsable: true
          },
          attrs
        )
      )

    q
  end

  setup do
    game = game_fixture()
    author = user_fixture("author")
    up_voter = user_fixture("upvoter")
    down_voter = user_fixture("downvoter")
    %{game: game, author: author, up_voter: up_voter, down_voter: down_voter}
  end

  describe "settle_votes/3" do
    test "confirmed: up settles correct (+1 point), down incorrect (0)", ctx do
      q = log(ctx.game, ctx.author)
      Games.set_community_vote(q.id, ctx.up_voter.id, "up")
      Games.set_community_vote(q.id, ctx.down_voter.id, "down")

      assert {:ok, {1, 1}} = Curation.settle_votes(q, :confirmed)

      assert Repo.reload!(ctx.up_voter).curator_points == 1
      assert Repo.reload!(ctx.down_voter).curator_points == 0

      up = Games.get_user_community_vote(q.id, ctx.up_voter.id)
      down = Games.get_user_community_vote(q.id, ctx.down_voter.id)
      assert up.settled_outcome == "correct" and up.settled_at
      assert down.settled_outcome == "incorrect" and down.settled_at
    end

    test "rejected: down settles correct, up incorrect", ctx do
      q = log(ctx.game, ctx.author)
      Games.set_community_vote(q.id, ctx.up_voter.id, "up")
      Games.set_community_vote(q.id, ctx.down_voter.id, "down")

      assert {:ok, {1, 1}} = Curation.settle_votes(q, :rejected)
      assert Repo.reload!(ctx.down_voter).curator_points == 1
      assert Repo.reload!(ctx.up_voter).curator_points == 0
    end

    test "settles at most once — second event is a no-op", ctx do
      q = log(ctx.game, ctx.author)
      Games.set_community_vote(q.id, ctx.up_voter.id, "up")

      assert {:ok, {1, 0}} = Curation.settle_votes(q, :confirmed)
      # Later demotion must not flip or re-award.
      assert {:ok, {0, 0}} = Curation.settle_votes(q, :rejected)

      assert Repo.reload!(ctx.up_voter).curator_points == 1
      vote = Games.get_user_community_vote(q.id, ctx.up_voter.id)
      assert vote.settled_outcome == "correct"
    end

    test "votes cast after the event never settle", ctx do
      q = log(ctx.game, ctx.author)
      event_at = NaiveDateTime.add(NaiveDateTime.utc_now(), -60, :second)
      Games.set_community_vote(q.id, ctx.up_voter.id, "up")

      assert {:ok, {0, 0}} = Curation.settle_votes(q, :confirmed, event_at)
      vote = Games.get_user_community_vote(q.id, ctx.up_voter.id)
      assert is_nil(vote.settled_at)
    end

    test "author self-confirm (weight 0) is excluded", ctx do
      q = log(ctx.game, ctx.author)
      Games.set_community_vote(q.id, ctx.author.id, "up")

      assert {:ok, {0, 0}} = Curation.settle_votes(q, :confirmed)
      assert Repo.reload!(ctx.author).curator_points == 0
    end

    test "admin votes never settle or earn points", ctx do
      admin = user_fixture("adminvoter")
      {:ok, admin} = Users.update_user_role(admin, "admin")
      q = log(ctx.game, ctx.author)
      Games.set_community_vote(q.id, admin.id, "up", true)
      Games.set_community_vote(q.id, ctx.up_voter.id, "up")

      assert {:ok, {1, 0}} = Curation.settle_votes(q, :confirmed)

      assert Repo.reload!(admin).curator_points == 0
      admin_vote = Games.get_user_community_vote(q.id, admin.id)
      assert is_nil(admin_vote.settled_at)
      assert is_nil(admin_vote.settled_outcome)
    end
  end

  describe "asker_stats/1" do
    test "counts asks, fresh first-asks, streak, and achievement progress", ctx do
      # Two fresh asks today + one pool hit (pool_source_id set).
      fresh = log(ctx.game, ctx.author, %{question: "Fresh 1?"})
      log(ctx.game, ctx.author, %{question: "Fresh 2?"})
      log(ctx.game, ctx.author, %{question: "Pool hit?", pool_source_id: fresh.id})

      stats = Curation.asker_stats(ctx.author.id)
      assert stats.asked == 3
      assert stats.fresh == 2
      assert stats.streak == 1

      by_key = Map.new(stats.achievements, &{&1.key, &1})
      assert by_key.first_ask.earned
      refute by_key.curious_mind.earned
      assert by_key.curious_mind.have == 3
      assert by_key.trailblazer.have == 2
      refute by_key.on_a_roll.earned
    end

    test "streak is 0 with no asks and lapses when the last ask is old", ctx do
      assert Curation.asker_stats(ctx.author.id).streak == 0

      old = log(ctx.game, ctx.author, %{question: "Old?"})

      old_ts = DateTime.utc_now() |> DateTime.add(-5, :day) |> DateTime.truncate(:second)

      {1, _} =
        RuleMaven.Repo.update_all(
          from(q in RuleMaven.Games.QuestionLog, where: q.id == ^old.id),
          set: [inserted_at: old_ts]
        )

      assert Curation.asker_stats(ctx.author.id).streak == 0
    end
  end

  describe "stats and notices" do
    test "curator_stats counts settles, caps monthly bonus, awards badges", ctx do
      # 11 correct settles → Curator badge (10) but not Sharp Eye (25).
      for i <- 1..11 do
        q = log(ctx.game, ctx.author, %{question: "Q#{i}?"})
        Games.set_community_vote(q.id, ctx.up_voter.id, "up")
        {:ok, {1, 0}} = Curation.settle_votes(q, :confirmed)
      end

      stats = Curation.curator_stats(ctx.up_voter.id)
      assert stats.points == 11
      assert stats.correct == 11
      assert stats.incorrect == 0
      assert stats.bonus_this_month == 11
      badge_keys = Enum.map(stats.badges, & &1.key)
      assert :curator in badge_keys
      refute :sharp_eye in badge_keys
    end

    test "bonus_asks_this_month is capped at bonus_cap", ctx do
      RuleMaven.Settings.put("curator_bonus_cap", "3")

      for i <- 1..5 do
        q = log(ctx.game, ctx.author, %{question: "Cap#{i}?"})
        Games.set_community_vote(q.id, ctx.up_voter.id, "up")
        {:ok, _} = Curation.settle_votes(q, :confirmed)
      end

      assert Curation.bonus_asks_this_month(ctx.up_voter.id) == 3
    end

    test "unseen_correct_count resets after mark_notices_seen", ctx do
      q = log(ctx.game, ctx.author)
      Games.set_community_vote(q.id, ctx.up_voter.id, "up")
      {:ok, _} = Curation.settle_votes(q, :confirmed)

      voter = Repo.reload!(ctx.up_voter)
      assert Curation.unseen_correct_count(voter) == 1

      :ok = Curation.mark_notices_seen(voter)
      assert Curation.unseen_correct_count(Repo.reload!(voter)) == 0
    end
  end

  describe "quota bonus" do
    test "correct settles raise the monthly quota", ctx do
      # Give the voter a base quota of 0 so any allowance comes from the bonus.
      Repo.update_all(
        from(u in RuleMaven.Users.User, where: u.id == ^ctx.up_voter.id),
        set: [
          monthly_quota: 0,
          email_confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )

      voter = Repo.reload!(ctx.up_voter)
      assert {:error, msg} = Games.check_rate_limit(voter)
      assert msg =~ "Monthly question quota reached (0)"

      q = log(ctx.game, ctx.author)
      Games.set_community_vote(q.id, voter.id, "up")
      {:ok, _} = Curation.settle_votes(q, :confirmed)

      assert :ok = Games.check_rate_limit(Repo.reload!(voter))
    end
  end

  describe "settled_history/2 and next_badge/1" do
    test "history returns newest-first entries with question and game", ctx do
      q1 = log(ctx.game, ctx.author, %{question: "First?"})
      q2 = log(ctx.game, ctx.author, %{question: "Second?"})
      Games.set_community_vote(q1.id, ctx.up_voter.id, "up")
      Games.set_community_vote(q2.id, ctx.up_voter.id, "up")

      {:ok, _} = Curation.settle_votes(q1, :confirmed)
      # Same-second settles fall back to the vote-id tiebreak (desc), so q2's
      # later vote still sorts first.
      {:ok, _} = Curation.settle_votes(q2, :rejected)

      assert [newer, older] = Curation.settled_history(ctx.up_voter.id)
      assert newer.question.id == q2.id
      assert newer.outcome == "incorrect"
      assert older.question.id == q1.id
      assert older.outcome == "correct"
      assert newer.game.id == ctx.game.id
    end

    test "next_badge tracks progress toward Curator first", ctx do
      assert %{label: "Curator", have: 0, need: 10} =
               Curation.next_badge(ctx.up_voter.id)

      q = log(ctx.game, ctx.author)
      Games.set_community_vote(q.id, ctx.up_voter.id, "up")
      {:ok, _} = Curation.settle_votes(q, :confirmed)

      assert %{label: "Curator", have: 1, need: 10} =
               Curation.next_badge(ctx.up_voter.id)
    end
  end
end
