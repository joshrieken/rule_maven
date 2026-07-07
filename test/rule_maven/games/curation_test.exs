defmodule RuleMaven.Games.CurationTest do
  use RuleMaven.DataCase

  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.{Curation, QuestionVote}
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
            pooled: true
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
  end
end
