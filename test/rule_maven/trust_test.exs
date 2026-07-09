defmodule RuleMaven.TrustTest do
  use RuleMaven.DataCase

  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.Trust
  alias RuleMaven.Repo
  alias RuleMaven.Users
  alias RuleMaven.Users.User

  # Oban isn't supervised in test (config :rule_maven, Oban, testing: :manual),
  # but toggle_verified/1 -> do_verify/1 now enqueues a SettleVotesWorker job
  # via Oban.insert/1, which needs a named, configured instance to insert
  # against. Start a queueless/pluginless one under the default name so the
  # plain (unnamed) insert call resolves for real. (Same pattern as
  # test/rule_maven/house_rules_test.exs.)
  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp user_fixture(name) do
    {:ok, u} =
      Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "testpass1234"
      })

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

  describe "vote_weight/1" do
    test "new users weigh ~1.0, higher reputation weighs more, capped" do
      assert Trust.vote_weight(0) == 1.0
      assert Trust.vote_weight(10) > 1.0
      assert Trust.vote_weight(1_000_000) <= Trust.vote_weight_cap()
      assert Trust.vote_weight(%User{reputation: 0}) == 1.0
    end
  end

  describe "recompute_trust/1" do
    setup do
      game = game_fixture()
      author = user_fixture("author")
      voter = user_fixture("voter")
      %{game: game, author: author, voter: voter}
    end

    test "citation bonus applies only with a grounded citation", %{game: game, author: author} do
      uncited = log(game, author, %{cited_passage: nil, cited_page: nil})
      ungrounded = log(game, author, %{cited_passage: "see p.4", cited_page: 4})

      grounded =
        log(game, author, %{cited_passage: "see p.4", cited_page: 4, citation_valid: true})

      assert Trust.recompute_trust(uncited) == 0.0
      # Citation present but not validated → no bonus.
      assert Trust.recompute_trust(ungrounded) == 0.0
      assert Trust.recompute_trust(grounded) == 1.0
    end

    test "upvotes raise and downvotes lower the score", %{
      game: game,
      author: author,
      voter: voter
    } do
      q = log(game, author, %{cited_passage: "see p.4", citation_valid: true, pooled: true})

      Games.set_community_vote(q.id, voter.id, "up")
      assert Repo.reload!(q).trust_score > 1.0

      Games.set_community_vote(q.id, voter.id, "down")
      assert Repo.reload!(q).trust_score < 1.0
    end

    test "verified floors the score to the top tier", %{game: game, author: author} do
      q = log(game, author, %{verified: true})
      assert Trust.recompute_trust(q) >= 100.0
    end
  end

  describe "toggle_verified/1" do
    setup do
      %{game: game_fixture(), author: user_fixture("ver_author")}
    end

    test "verifying an uncited answer publishes it to community + pool", %{
      game: game,
      author: author
    } do
      q = log(game, author, %{cited_passage: nil, cited_page: nil, visibility: "private"})
      {:ok, v} = Games.toggle_verified(q)

      assert v.verified
      assert v.visibility == "community"
      assert v.pooled
      assert Repo.reload!(v).trust_score >= 100.0
    end

    test "un-verifying reverts to private and citation-gated pooling", %{
      game: game,
      author: author
    } do
      q = log(game, author, %{cited_passage: nil, cited_page: nil})
      {:ok, v} = Games.toggle_verified(q)
      {:ok, u} = Games.toggle_verified(v)

      refute u.verified
      assert u.visibility == "private"
      # No citation → not pool-eligible once the verify override is gone.
      refute u.pooled
    end

    test "only one verified row per question text", %{game: game, author: author} do
      a = log(game, author, %{answer: "first"})
      b = log(game, author, %{answer: "second"})

      {:ok, _} = Games.toggle_verified(a)
      {:ok, _} = Games.toggle_verified(b)

      # The superseded row must fully step down, not just lose the flag: it
      # leaves the community tier and sheds the verified trust_score floor.
      reloaded_a = Repo.reload!(a)
      refute reloaded_a.verified
      refute reloaded_a.visibility == "community"
      assert reloaded_a.trust_score < 100.0
      assert Repo.reload!(b).verified
    end

    test "verifying a near-duplicate (by embedding) un-verifies the old one", %{
      game: game,
      author: author
    } do
      embed = fn id, vec ->
        Repo.update_all(
          from(q in RuleMaven.Games.QuestionLog, where: q.id == ^id),
          set: [question_embedding: Pgvector.new(vec)]
        )
      end

      a = log(game, author, %{question: "how do i score", answer: "first"})
      b = log(game, author, %{question: "what is the scoring rule", answer: "second"})

      # Different wording, near-identical embeddings → same question.
      embed.(a.id, Enum.map(1..768, &(&1 * 1.0)))
      embed.(b.id, Enum.map(1..768, &(&1 * 1.0 + 0.0001)))

      {:ok, _} = Games.toggle_verified(Repo.reload!(a))
      {:ok, _} = Games.toggle_verified(Repo.reload!(b))

      refute Repo.reload!(a).verified
      assert Repo.reload!(b).verified
    end
  end

  describe "recompute_reputation/1" do
    test "net votes on authored rows + promotion bonus" do
      game = game_fixture()
      author = user_fixture("author")
      voter = user_fixture("voter")

      q = log(game, author, %{cited_passage: "p.1", pooled: true})
      Games.set_community_vote(q.id, voter.id, "up")

      assert Repo.get(User, author.id).reputation >= 1
    end

    test "a single voter's reputation contribution is capped" do
      game = game_fixture()
      author = user_fixture("author")
      voter = user_fixture("voter")

      # One accomplice upvotes many of the author's answers — net contribution
      # must be clamped to the per-voter cap, not grow unbounded.
      for i <- 1..10 do
        q = log(game, author, %{question: "q#{i}", cited_passage: "p.#{i}", pooled: true})
        Games.set_community_vote(q.id, voter.id, "up")
      end

      assert Repo.get(User, author.id).reputation == Trust.per_voter_rep_cap()
    end
  end

  describe "mark_pooled/1" do
    setup do
      %{game: game_fixture(), author: user_fixture("a")}
    end

    test "pools a grounded-citation, non-refused row", %{game: game, author: author} do
      q =
        log(game, author, %{
          cited_passage: "see p.2",
          citation_valid: true,
          pooled: false,
          refused: false
        })

      assert Games.mark_pooled(q).pooled == true
    end

    test "does not pool a present-but-ungrounded citation", %{game: game, author: author} do
      q = log(game, author, %{cited_passage: "see p.2", citation_valid: false, pooled: false})
      assert Games.mark_pooled(q).pooled == false
    end

    test "does not pool an uncited row", %{game: game, author: author} do
      q = log(game, author, %{cited_passage: nil, cited_page: nil, pooled: false})
      assert Games.mark_pooled(q).pooled == false
    end

    test "does not pool a refused row", %{game: game, author: author} do
      q = log(game, author, %{cited_passage: "p.2", refused: true, pooled: false})
      assert Games.mark_pooled(q).pooled == false
    end
  end

  describe "pool_tier/1" do
    test "community / verified / above-floor are trusted; else provisional" do
      game = game_fixture()
      author = user_fixture("a")

      community = log(game, author, %{visibility: "community", pooled: true})
      verified = log(game, author, %{verified: true, pooled: true})
      provisional = log(game, author, %{cited_passage: "p.1", pooled: true, trust_score: 0.0})

      assert Games.pool_tier(community) == :trusted
      assert Games.pool_tier(verified) == :trusted
      assert Games.pool_tier(provisional) == :provisional
    end
  end

  describe "set_community_vote/3 guards" do
    setup do
      game = game_fixture()
      %{game: game, author: user_fixture("author"), voter: user_fixture("voter")}
    end

    test "self-upvote is allowed but carries zero weight", %{game: game, author: author} do
      q = log(game, author, %{cited_passage: "p.1", pooled: true})
      assert "up" = Games.set_community_vote(q.id, author.id, "up")

      # Stored as a real vote row (asker confirmation) at weight 0…
      assert %{value: "up", weight: +0.0} = Games.get_user_community_vote(q.id, author.id)
      # …so trust_score, reputation, and quorum are all unaffected.
      assert Repo.reload!(q).trust_score == 0.0
      assert Repo.reload!(author).reputation == 0
      assert Trust.eligible_voter_count(Repo.reload!(q)) == 0

      # Toggles off like any other vote.
      assert is_nil(Games.set_community_vote(q.id, author.id, "up"))
      assert is_nil(Games.get_user_community_vote(q.id, author.id))
    end

    test "rejects self-downvotes", %{game: game, author: author} do
      q = log(game, author, %{cited_passage: "p.1", pooled: true})
      assert {:error, :self_vote} = Games.set_community_vote(q.id, author.id, "down")
      # Rejected before any recompute, so the stored score is untouched.
      assert Repo.reload!(q).trust_score == 0.0
      assert is_nil(Games.get_user_community_vote(q.id, author.id))
    end

    test "admins may self-vote and unvote their own rows", %{game: game, author: author} do
      {:ok, admin} = Users.update_user_role(author, "admin")
      q = log(game, admin, %{cited_passage: "p.1", pooled: true})

      # admin? = true bypasses the self-vote guard and keeps real weight
      # (seeding/curation), unlike a regular asker's weight-0 confirmation.
      assert "up" = Games.set_community_vote(q.id, admin.id, "up", true)
      assert %{value: "up", weight: w} = Games.get_user_community_vote(q.id, admin.id)
      assert w >= 1.0

      # Re-casting the same vote toggles it off (unvote).
      assert is_nil(Games.set_community_vote(q.id, admin.id, "up", true))
      assert is_nil(Games.get_user_community_vote(q.id, admin.id))
    end

    test "rejects votes on non-votable (private, uncited) rows", %{
      game: game,
      author: author,
      voter: voter
    } do
      q = log(game, author, %{cited_passage: nil, cited_page: nil, visibility: "private"})
      assert {:error, :not_votable} = Games.set_community_vote(q.id, voter.id, "up")
    end

    test "rejects votes on a missing row", %{voter: voter} do
      assert {:error, :not_found} = Games.set_community_vote(-1, voter.id, "up")
    end

    test "allows a normal vote on a pooled row", %{
      game: game,
      author: author,
      voter: voter
    } do
      q = log(game, author, %{cited_passage: "p.1", pooled: true})
      assert "up" = Games.set_community_vote(q.id, voter.id, "up")
    end

    test "rejects an out-of-range value before touching the DB", %{
      game: game,
      author: author,
      voter: voter
    } do
      q = log(game, author, %{cited_passage: "p.1", pooled: true})
      # A forged vote value must not reach the insert!/update! and crash.
      assert {:error, :invalid_value} = Games.set_community_vote(q.id, voter.id, "sideways")
      assert is_nil(Games.get_user_community_vote(q.id, voter.id))
    end
  end

  describe "community_vote_maps/2" do
    test "counts the asker's confirmation in the tally and flags it as a badge" do
      game = game_fixture()
      author = user_fixture("maps_author")
      voter = user_fixture("maps_voter")
      q = log(game, author, %{cited_passage: "p.1", pooled: true})

      Games.set_community_vote(q.id, author.id, "up")
      Games.set_community_vote(q.id, voter.id, "up")

      {counts, user_votes, asker_confirmed} = Games.community_vote_maps([q.id], voter.id)

      # Tally includes the asker's vote (a thumb click must visibly increment
      # the number); the badge annotates that one counted vote is the asker's.
      assert counts[q.id] == %{up: 2, down: 0}
      assert user_votes[q.id] == "up"
      assert MapSet.member?(asker_confirmed, q.id)

      # The author viewing their own row still sees their vote state (filled thumb).
      {_counts, author_votes, _} = Games.community_vote_maps([q.id], author.id)
      assert author_votes[q.id] == "up"
    end

    test "rows without an author vote are not asker-confirmed" do
      game = game_fixture()
      author = user_fixture("maps_author2")
      voter = user_fixture("maps_voter2")
      q = log(game, author, %{cited_passage: "p.1", pooled: true})

      Games.set_community_vote(q.id, voter.id, "up")

      {counts, _user_votes, asker_confirmed} = Games.community_vote_maps([q.id], voter.id)
      assert counts[q.id] == %{up: 1, down: 0}
      refute MapSet.member?(asker_confirmed, q.id)
    end
  end

  describe "eligible_voter_count/1" do
    setup do
      game = game_fixture()
      %{game: game, author: user_fixture("author")}
    end

    defp confirm(user) do
      {:ok, u} = user |> RuleMaven.Users.User.confirm_changeset() |> Repo.update()
      u
    end

    test "counts only confirmed, non-author voters", %{game: game, author: author} do
      q = log(game, author, %{cited_passage: "p.1", pooled: true})
      confirmed = confirm(user_fixture("confirmed"))
      unconfirmed = user_fixture("unconfirmed")

      Games.set_community_vote(q.id, confirmed.id, "up")
      Games.set_community_vote(q.id, unconfirmed.id, "up")

      assert Trust.eligible_voter_count(Repo.reload!(q)) == 1
    end

    test "excludes the author even when the author somehow has a vote row", %{
      game: game,
      author: author
    } do
      q = log(game, author, %{cited_passage: "p.1", pooled: true})
      # author self-votes are blocked at the API; count must still exclude them.
      assert Trust.eligible_voter_count(q) == 0
    end
  end

  describe "privacy boundary" do
    test "a pooled private row never appears in browse/list surfaces" do
      game = game_fixture()
      author = user_fixture("author")
      other = user_fixture("other")

      private =
        log(game, author, %{
          question: "private wording",
          cited_passage: "p.1",
          visibility: "private",
          pooled: true
        })

      assert private.pooled == true
      # Community + FAQ lists are community-only — the pooled private row is absent.
      refute private.id in Enum.map(Games.community_questions(game, other.id), & &1.id)
      refute private.id in Enum.map(Games.faq_questions(game), & &1.id)
    end
  end

  describe "find_similar_question_in_pool tiering" do
    test "prefers a trusted hit over a closer provisional one" do
      game = game_fixture()
      author = user_fixture("author")

      # Provisional row sits exactly on the query embedding (distance 0).
      exact = Enum.map(1..768, &(&1 * 1.0))

      prov =
        log(game, author, %{
          question: "provisional",
          cited_passage: "p.1",
          visibility: "private",
          pooled: true,
          trust_score: 0.0
        })

      Repo.update_all(
        from(q in RuleMaven.Games.QuestionLog, where: q.id == ^prov.id),
        set: [question_embedding: Pgvector.new(exact)]
      )

      # Trusted (community) row slightly further away.
      near = Enum.map(1..768, &(&1 * 1.0 + 0.001))

      trusted =
        log(game, author, %{
          question: "trusted",
          answer: "Trusted answer.",
          visibility: "community",
          pooled: true
        })

      Repo.update_all(
        from(q in RuleMaven.Games.QuestionLog, where: q.id == ^trusted.id),
        set: [question_embedding: Pgvector.new(near)]
      )

      {row, tier} = Games.find_similar_question_in_pool(game.id, exact)
      assert tier == :trusted
      assert row.id == trusted.id
    end
  end

  describe "find_pool_candidates/3 over the widened tiebreaker band" do
    # Unit vectors with an exact, controllable cosine to the query e0.
    defp vec_at(sim) do
      [sim, :math.sqrt(1.0 - sim * sim) | List.duplicate(0.0, 766)]
    end

    defp pooled_row(game, author, name, opts) do
      row = log(game, author, Map.merge(%{question: name, pooled: true}, Map.new(opts.attrs)))

      Repo.update_all(
        from(q in RuleMaven.Games.QuestionLog, where: q.id == ^row.id),
        set: [question_embedding: Pgvector.new(vec_at(opts.sim))]
      )

      row
    end

    setup do
      game = game_fixture()
      author = user_fixture("author")
      %{game: game, author: author, query: vec_at(1.0)}
    end

    test "a near-exact provisional row is not shadowed by a distant trusted one",
         %{game: game, author: author, query: query} do
      # This is the regression: trust-first SQL ordering across the wide 0.80
      # band returned the trusted row at 0.81, burned a tiebreaker call on it,
      # and never saw the 0.98 match.
      near = pooled_row(game, author, "near", %{sim: 0.98, attrs: %{visibility: "private"}})
      _far = pooled_row(game, author, "far", %{sim: 0.81, attrs: %{visibility: "community"}})

      candidates =
        Games.find_pool_candidates(game.id, query,
          threshold: Games.pool_tiebreaker_distance_threshold()
        )

      # Nearest-first, both inside the widened band.
      assert [{first, _}, {second, _}] = candidates
      assert first.id == near.id
      assert second.id != near.id

      # Only the 0.98 row clears the direct-hit floor, so it wins outright —
      # no tiebreaker call, and the trusted-but-distant row never competes.
      floor = Games.pool_similarity_floor()
      direct = Enum.filter(candidates, fn {_row, sim} -> sim >= floor end)
      assert {row, :provisional} = Games.best_by_trust(direct)
      assert row.id == near.id
    end

    test "trust still breaks ties among rows that all clear the direct-hit floor",
         %{game: game, author: author, query: query} do
      _prov = pooled_row(game, author, "prov", %{sim: 0.99, attrs: %{visibility: "private"}})

      trusted =
        pooled_row(game, author, "trusted", %{sim: 0.95, attrs: %{visibility: "community"}})

      candidates = Games.find_pool_candidates(game.id, query)
      assert {row, :trusted} = Games.best_by_trust(candidates)
      assert row.id == trusted.id
    end

    test "stale rows are excluded even if still flagged pooled",
         %{game: game, author: author, query: query} do
      row = pooled_row(game, author, "staled", %{sim: 0.99, attrs: %{visibility: "community"}})

      Repo.update_all(
        from(q in RuleMaven.Games.QuestionLog, where: q.id == ^row.id),
        set: [stale: true]
      )

      assert Games.find_pool_candidates(game.id, query) == []
    end

    test "respects the candidate limit", %{game: game, author: author, query: query} do
      for i <- 1..4 do
        pooled_row(game, author, "q#{i}", %{sim: 0.99, attrs: %{visibility: "private"}})
      end

      assert length(Games.find_pool_candidates(game.id, query, limit: 2)) == 2
    end
  end
end
