defmodule RuleMaven.CommunityBrowseTest do
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures

  alias RuleMaven.Games

  defp user_fixture(name) do
    {:ok, u} =
      RuleMaven.Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "testpass1234"
      })

    u
  end

  defp log(game, attrs) do
    {:ok, q} =
      Games.log_question(
        Map.merge(
          %{game_id: game.id, question: "How does X work?", answer: "Like Y."},
          attrs
        )
      )

    q
  end

  describe "unverified_pool_questions/2" do
    setup do
      %{game: game_fixture()}
    end

    test "includes pooled, private, healthy rows", %{game: game} do
      q =
        log(game, %{pooled: true, browsable: true, promoted: false, question: "Eligible?"})

      ids = game |> Games.unverified_pool_questions() |> Enum.map(& &1.id)
      assert q.id in ids
    end

    test "excludes ineligible rows", %{game: game} do
      source = log(game, %{pooled: true, browsable: true, question: "the pool source"})

      ineligible = [
        %{pooled: false, question: "not pooled"},
        %{pooled: true, promoted: true, question: "already community"},
        %{pooled: true, refused: true, question: "refused"},
        %{pooled: true, needs_review: true, question: "under review"},
        %{pooled: true, blocked: true, question: "blocked"},
        %{pooled: true, stale: true, question: "stale"},
        %{pooled: true, error_kind: "timeout", question: "errored"},
        %{pooled: true, pool_source_id: source.id, question: "pool hit"},
        %{pooled: true, trust_score: -2.0, question: "downvoted"}
      ]

      for attrs <- ineligible, do: log(game, attrs)

      assert game |> Games.unverified_pool_questions() |> Enum.map(& &1.id) == [source.id]
    end

    test "orders by trust_score, then recency", %{game: game} do
      low = log(game, %{pooled: true, browsable: true, trust_score: 0.5, question: "low"})
      high = log(game, %{pooled: true, browsable: true, trust_score: 3.0, question: "high"})

      assert game |> Games.unverified_pool_questions() |> Enum.map(& &1.id) ==
               [high.id, low.id]
    end

    test "excludes unbrowsable rows", %{game: game} do
      shown = log(game, %{pooled: true, browsable: true, question: "browsable"})
      hidden = log(game, %{pooled: true, browsable: false, question: "hidden group row"})

      ids = game |> Games.unverified_pool_questions() |> Enum.map(& &1.id)
      assert shown.id in ids
      refute hidden.id in ids
    end
  end

  describe "recent_questions/3 upvoted pooled rows" do
    setup do
      %{game: game_fixture(), asker: user_fixture("cb_asker"), viewer: user_fixture("cb_viewer")}
    end

    test "another user's pooled question appears in my list only after I upvote it",
         %{game: game, asker: asker, viewer: viewer} do
      q =
        log(game, %{
          user_id: asker.id,
          pooled: true,
          browsable: true,
          promoted: false,
          question: "Do walls block movement?"
        })

      before_ids = game |> Games.recent_questions(20, user_id: viewer.id) |> Enum.map(& &1.id)
      refute q.id in before_ids

      assert "up" = Games.set_community_vote(q.id, viewer.id, "up")

      after_ids = game |> Games.recent_questions(20, user_id: viewer.id) |> Enum.map(& &1.id)
      assert q.id in after_ids
    end

    test "removing the upvote removes it from my list again",
         %{game: game, asker: asker, viewer: viewer} do
      q = log(game, %{user_id: asker.id, pooled: true, promoted: false})

      Games.set_community_vote(q.id, viewer.id, "up")
      # Same vote again toggles it off.
      Games.set_community_vote(q.id, viewer.id, "up")

      ids = game |> Games.recent_questions(20, user_id: viewer.id) |> Enum.map(& &1.id)
      refute q.id in ids
    end
  end
end
