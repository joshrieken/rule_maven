defmodule RuleMaven.GamesGroupCacheTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.Games
  alias RuleMaven.GamesFixtures
  alias RuleMaven.GroupsFixtures

  # No AccountsFixtures/user_fixture helper in this repo — build users
  # directly via the Users context, unique email/username per call.
  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{
            username: "#{prefix}_user_#{System.unique_integer([:positive])}",
            email: "#{prefix}_user_#{System.unique_integer([:positive])}@test.com",
            password: "password1234"
          },
          attrs
        )
      )

    user
  end

  # question_embedding is Pgvector.Ecto.Vector; existing pool tests in
  # games_expansion_cache_test.exs use a 768-dim unit vector, so match that
  # dimensionality here rather than guessing 1536.
  @emb Pgvector.new([1.0 | List.duplicate(0.0, 767)])

  setup do
    game = GamesFixtures.game_fixture(bgg_id: 4201)
    owner = create_user("owner")
    grp = GroupsFixtures.group_fixture(owner)

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "group q",
        answer: "42",
        visibility: "private",
        group_id: grp.id,
        citation_valid: true
      })

    # log_question doesn't accept question_embedding directly in every path
    # here — set it via update so the row is guaranteed to carry the exact
    # vector under test, independent of embed wiring.
    RuleMaven.Repo.update_all(
      Ecto.Query.from(x in RuleMaven.Games.QuestionLog, where: x.id == ^q.id),
      set: [question_embedding: @emb]
    )

    q = RuleMaven.Repo.get!(RuleMaven.Games.QuestionLog, q.id)

    %{game: game, grp: grp, owner: owner, q: q}
  end

  test "member ask sees the group row as a candidate", %{game: g, grp: grp, q: q} do
    ids =
      Games.find_pool_candidates(g.id, @emb, active_group_id: grp.id)
      |> Enum.map(fn {row, _sim} -> row.id end)

    assert q.id in ids
  end

  test "without active_group_id the private group row is NOT a candidate (no leak into the normal pool)",
       %{game: g, q: q} do
    ids =
      Games.find_pool_candidates(g.id, @emb, [])
      |> Enum.map(fn {row, _sim} -> row.id end)

    refute q.id in ids
  end

  test "a non-member's group_id is dropped by the membership gate LLM.ask enforces", %{
    grp: grp,
    owner: owner
  } do
    outsider = create_user("outsider")

    # This mirrors the exact gate in RuleMaven.LLM.ask/5: a caller-supplied
    # group_id (which arrives downstream of a client — LiveView assign or
    # Oban job arg — and so cannot be trusted on its own) is only forwarded
    # as `active_group_id` to find_pool_candidates/3 when
    # `member_of_group_id?/2` confirms it for the ALSO-passed user_id. For a
    # non-member that check fails and the widening never happens; for the
    # real owner/member it succeeds.
    refute RuleMaven.Groups.member_of_group_id?(outsider.id, grp.id)
    assert RuleMaven.Groups.member_of_group_id?(owner.id, grp.id)
  end

  test "stale group row is excluded even with active_group_id set", %{game: g, grp: grp, owner: owner} do
    {:ok, stale_q} =
      Games.log_question(%{
        game_id: g.id,
        user_id: owner.id,
        question: "stale group q",
        answer: "stale answer",
        visibility: "private",
        group_id: grp.id,
        citation_valid: true,
        stale: true
      })

    RuleMaven.Repo.update_all(
      Ecto.Query.from(x in RuleMaven.Games.QuestionLog, where: x.id == ^stale_q.id),
      set: [question_embedding: @emb]
    )

    ids =
      Games.find_pool_candidates(g.id, @emb, active_group_id: grp.id)
      |> Enum.map(fn {row, _sim} -> row.id end)

    refute stale_q.id in ids
  end

  test "needs_review group row is excluded even with active_group_id set", %{
    game: g,
    grp: grp,
    owner: owner
  } do
    {:ok, nr_q} =
      Games.log_question(%{
        game_id: g.id,
        user_id: owner.id,
        question: "needs review group q",
        answer: "unreviewed answer",
        visibility: "private",
        group_id: grp.id,
        citation_valid: true,
        needs_review: true
      })

    RuleMaven.Repo.update_all(
      Ecto.Query.from(x in RuleMaven.Games.QuestionLog, where: x.id == ^nr_q.id),
      set: [question_embedding: @emb]
    )

    ids =
      Games.find_pool_candidates(g.id, @emb, active_group_id: grp.id)
      |> Enum.map(fn {row, _sim} -> row.id end)

    refute nr_q.id in ids
  end

  test "expansion mismatch excludes the group row even with active_group_id set", %{
    game: g,
    grp: grp,
    owner: owner
  } do
    {:ok, exp_q} =
      Games.log_question(%{
        game_id: g.id,
        user_id: owner.id,
        question: "expansion group q",
        answer: "expansion answer",
        visibility: "private",
        group_id: grp.id,
        citation_valid: true,
        expansion_ids: [7]
      })

    RuleMaven.Repo.update_all(
      Ecto.Query.from(x in RuleMaven.Games.QuestionLog, where: x.id == ^exp_q.id),
      set: [question_embedding: @emb]
    )

    ids =
      Games.find_pool_candidates(g.id, @emb, active_group_id: grp.id)
      |> Enum.map(fn {row, _sim} -> row.id end)

    refute exp_q.id in ids

    ids_matching =
      Games.find_pool_candidates(g.id, @emb, active_group_id: grp.id, expansion_ids: [7])
      |> Enum.map(fn {row, _sim} -> row.id end)

    assert exp_q.id in ids_matching
  end

  test "non-group lookups (community pool) are unaffected by active_group_id support", %{
    game: g,
    owner: owner
  } do
    {:ok, community_q} =
      Games.log_question(%{
        game_id: g.id,
        user_id: owner.id,
        question: "community q",
        answer: "community answer",
        visibility: "community",
        citation_valid: true
      })

    RuleMaven.Repo.update_all(
      Ecto.Query.from(x in RuleMaven.Games.QuestionLog, where: x.id == ^community_q.id),
      set: [question_embedding: @emb]
    )

    ids_no_group =
      Games.find_pool_candidates(g.id, @emb, [])
      |> Enum.map(fn {row, _sim} -> row.id end)

    assert community_q.id in ids_no_group

    ids_with_group =
      Games.find_pool_candidates(g.id, @emb, active_group_id: 999_999_999)
      |> Enum.map(fn {row, _sim} -> row.id end)

    assert community_q.id in ids_with_group
  end
end
