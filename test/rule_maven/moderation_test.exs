defmodule RuleMaven.ModerationTest do
  use RuleMaven.DataCase

  import RuleMaven.GamesFixtures

  alias RuleMaven.{Games, Moderation, Users}

  # Oban isn't supervised in test (config :rule_maven, Oban, testing: :manual),
  # but demote_user_answers/1 now enqueues a SettleVotesWorker job per row via
  # Oban.insert/1, which needs a named, configured instance to insert against.
  # Start a queueless/pluginless one under the default name so the plain
  # (unnamed) insert call resolves for real. (Same pattern as
  # test/rule_maven/house_rules_test.exs.)
  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp user_fixture(name, attrs \\ %{}) do
    {:ok, u} =
      Users.create_user(
        Map.merge(
          %{username: name, email: "#{name}@test.com", password: "testpass1234"},
          attrs
        )
      )

    u
  end

  defp log(game, author, attrs) do
    {:ok, q} =
      Games.log_question(
        Map.merge(
          %{
            game_id: game.id,
            question: "How does X work?",
            answer: "It works like Y.",
            user_id: author && author.id
          },
          attrs
        )
      )

    q
  end

  describe "user_signals/0" do
    test "aggregates answer counts and flags risky users" do
      game = game_fixture()
      bad = user_fixture("bad")
      good = user_fixture("good")

      log(game, bad, %{blocked: true})
      log(game, bad, %{refused: true})
      log(game, bad, %{citation_valid: false})
      log(game, good, %{citation_valid: true, visibility: "community", pooled: true})

      signals = Moderation.user_signals()
      by_name = Map.new(signals, &{&1.username, &1})

      assert by_name["bad"].blocked == 1
      assert by_name["bad"].refused == 1
      assert by_name["bad"].citation_invalid >= 1
      assert by_name["bad"].risk > by_name["good"].risk
      assert by_name["good"].community == 1

      # Highest risk sorts first.
      assert hd(signals).username == "bad"
    end

    test "counts votes cast per user" do
      game = game_fixture()
      author = user_fixture("auth")
      voter = user_fixture("voter")
      q = log(game, author, %{cited_passage: "p.1", pooled: true, browsable: true})

      Games.set_community_vote(q.id, voter.id, "up")

      sig = Enum.find(Moderation.user_signals(), &(&1.username == "voter"))
      assert sig.votes_up == 1
      assert sig.votes_down == 0
    end

    test "self-votes (asker confirmations) don't count as votes cast" do
      game = game_fixture()
      author = user_fixture("selfvoter")
      q = log(game, author, %{cited_passage: "p.1", pooled: true})

      assert "up" = Games.set_community_vote(q.id, author.id, "up")

      sig = Enum.find(Moderation.user_signals(), &(&1.username == "selfvoter"))
      assert sig.votes_up == 0
      assert sig.votes_down == 0
    end
  end

  describe "collusion_pairs/0" do
    test "surfaces a voter repeatedly boosting one author, excludes self-votes" do
      game = game_fixture()
      author = user_fixture("ringauthor")
      accomplice = user_fixture("accomplice")

      for i <- 1..3 do
        q =
          log(game, author, %{
            question: "q#{i}",
            cited_passage: "p.#{i}",
            pooled: true,
            browsable: true
          })
        Games.set_community_vote(q.id, accomplice.id, "up")
      end

      pairs = Moderation.collusion_pairs(2)
      pair = Enum.find(pairs, &(&1.voter_name == "accomplice"))

      assert pair.author_name == "ringauthor"
      assert pair.votes == 3
      assert pair.ups == 3
    end

    test "returns nothing below threshold" do
      game = game_fixture()
      author = user_fixture("a2")
      voter = user_fixture("v2")
      q = log(game, author, %{cited_passage: "p.1", pooled: true})
      Games.set_community_vote(q.id, voter.id, "up")

      assert Moderation.collusion_pairs(5) == []
    end
  end

  describe "invalidate_pool/1 does not inflate moderation risk" do
    test "a rulebook edit doesn't touch needs_review-based abuse stats for private askers" do
      game = game_fixture()
      asker = user_fixture("ordinary_asker")

      # Two private answers — no reports, no community promotion. An ordinary
      # user just asking questions.
      log(game, asker, %{visibility: "private", citation_valid: true})
      log(game, asker, %{visibility: "private", citation_valid: true})

      before_stats = Enum.find(Moderation.user_signals(), &(&1.username == "ordinary_asker"))
      assert before_stats.needs_review == 0
      assert before_stats.risk == 0

      # Simulate a rulebook edit: invalidate_pool marks the private rows
      # `stale`, but must NOT set `needs_review` on them (that's the
      # moderation-abuse signal, reserved for community/report-driven flags).
      Games.invalidate_pool(game.id)

      after_stats = Enum.find(Moderation.user_signals(), &(&1.username == "ordinary_asker"))
      assert after_stats.needs_review == 0
      assert after_stats.risk == before_stats.risk
    end
  end

  describe "Games.demote_user_answers/1" do
    test "makes all of a user's answers private and unpools them" do
      game = game_fixture()
      author = user_fixture("offender")

      a = log(game, author, %{visibility: "community", pooled: true, citation_valid: true})
      b = log(game, author, %{verified: true, pooled: true})

      assert Games.demote_user_answers(author.id) == 2

      a = Repo.reload(a)
      b = Repo.reload(b)
      assert a.visibility == "private" and a.pooled == false
      assert b.visibility == "private" and b.pooled == false and b.verified == false
    end
  end
end
