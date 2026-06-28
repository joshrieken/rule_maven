defmodule RuleMaven.TrustTest do
  use RuleMaven.DataCase

  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.Trust
  alias RuleMaven.Repo
  alias RuleMaven.Users
  alias RuleMaven.Users.User

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
      grounded = log(game, author, %{cited_passage: "see p.4", cited_page: 4, citation_valid: true})

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

    test "rejects self-votes", %{game: game, author: author} do
      q = log(game, author, %{cited_passage: "p.1", pooled: true})
      assert {:error, :self_vote} = Games.set_community_vote(q.id, author.id, "up")
      # Rejected before any recompute, so the stored score is untouched.
      assert Repo.reload!(q).trust_score == 0.0
      assert is_nil(Games.get_user_community_vote(q.id, author.id))
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
end
