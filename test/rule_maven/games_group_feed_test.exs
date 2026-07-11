defmodule RuleMaven.GamesGroupFeedTest do
  @moduledoc """
  Task 8: `Games.recent_questions/3` with `opts[:group_id]` returns the
  group's feed for a game — scoped by game AND group, newest first,
  attributed (asker preloaded), excluding refused/blocked rows. With no
  `group_id`, behavior must be byte-identical to the pre-existing
  own+community+upvoted union (regression coverage below).
  """
  use RuleMaven.DataCase, async: true

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.GamesFixtures
  alias RuleMaven.GroupsFixtures

  defp create_user(prefix) do
    Repo.insert!(%RuleMaven.Users.User{
      username: "#{prefix}_#{System.unique_integer([:positive])}",
      email: "#{prefix}_#{System.unique_integer([:positive])}@test.com",
      password_hash: "x"
    })
  end

  setup do
    game = GamesFixtures.game_fixture()
    owner = create_user("feed_owner")
    other = create_user("feed_other")
    grp = GroupsFixtures.group_fixture(owner)

    %{game: game, owner: owner, other: other, grp: grp}
  end

  test "returns the group's rows for the game, not another user's non-group rows", %{
    game: game,
    owner: owner,
    other: other,
    grp: grp
  } do
    {:ok, group_q} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "group question",
        answer: "group answer",
        visibility: "private",
        group_id: grp.id
      })

    {:ok, _solo} =
      Games.log_question(%{
        game_id: game.id,
        user_id: other.id,
        question: "solo question",
        answer: "solo answer",
        visibility: "private"
      })

    feed = Games.recent_questions(game, 20, group_id: grp.id)
    ids = Enum.map(feed, & &1.id)

    assert group_q.id in ids
    refute Enum.any?(feed, fn q -> q.question == "solo question" end)
  end

  test "does not return rows belonging to a different group", %{
    game: game,
    owner: owner,
    grp: grp
  } do
    other_owner = create_user("feed_other_owner")
    other_grp = GroupsFixtures.group_fixture(other_owner)

    {:ok, in_group} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "in this group",
        answer: "a",
        visibility: "private",
        group_id: grp.id
      })

    {:ok, _other_group_q} =
      Games.log_question(%{
        game_id: game.id,
        user_id: other_owner.id,
        question: "in the other group",
        answer: "a",
        visibility: "private",
        group_id: other_grp.id
      })

    feed = Games.recent_questions(game, 20, group_id: grp.id)
    ids = Enum.map(feed, & &1.id)

    assert in_group.id in ids
    refute Enum.any?(feed, fn q -> q.question == "in the other group" end)
  end

  test "does not return rows for a different game", %{owner: owner, grp: grp} do
    game = GamesFixtures.game_fixture(%{bgg_id: 9001, name: "Game A"})
    other_game = GamesFixtures.game_fixture(%{bgg_id: 9002, name: "Game B"})

    {:ok, this_game_q} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "on game A",
        answer: "a",
        visibility: "private",
        group_id: grp.id
      })

    {:ok, _other_game_q} =
      Games.log_question(%{
        game_id: other_game.id,
        user_id: owner.id,
        question: "on game B",
        answer: "a",
        visibility: "private",
        group_id: grp.id
      })

    feed = Games.recent_questions(game, 20, group_id: grp.id)
    ids = Enum.map(feed, & &1.id)

    assert this_game_q.id in ids
    refute Enum.any?(feed, fn q -> q.question == "on game B" end)
  end

  test "excludes refused/blocked rows", %{game: game, owner: owner, grp: grp} do
    {:ok, clean} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "clean question",
        answer: "a",
        visibility: "private",
        group_id: grp.id
      })

    {:ok, refused} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "refused question",
        answer: "⚠️ refused",
        visibility: "private",
        group_id: grp.id,
        refused: true
      })

    {:ok, blocked} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "blocked question",
        answer: "⚠️ blocked",
        visibility: "private",
        group_id: grp.id,
        blocked: true
      })

    feed = Games.recent_questions(game, 20, group_id: grp.id)
    ids = Enum.map(feed, & &1.id)

    assert clean.id in ids
    refute refused.id in ids
    refute blocked.id in ids
  end

  test "preloads the asker for attribution", %{game: game, owner: owner, grp: grp} do
    {:ok, _q} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "attribution question",
        answer: "a",
        visibility: "private",
        group_id: grp.id
      })

    [row] = Games.recent_questions(game, 20, group_id: grp.id)

    assert %RuleMaven.Users.User{} = row.user
    assert row.user.id == owner.id
  end

  test "regression: recent_questions/3 with only user_id behaves exactly as before", %{
    game: game,
    owner: owner,
    other: other
  } do
    {:ok, own} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "my own question",
        answer: "a",
        visibility: "private"
      })

    {:ok, community} =
      Games.log_question(%{
        game_id: game.id,
        user_id: other.id,
        question: "community question",
        answer: "a",
        visibility: "community"
      })

    {:ok, unrelated} =
      Games.log_question(%{
        game_id: game.id,
        user_id: other.id,
        question: "someone else's private question",
        answer: "a",
        visibility: "private"
      })

    feed = Games.recent_questions(game, 20, user_id: owner.id)
    ids = Enum.map(feed, & &1.id)

    assert own.id in ids
    assert community.id in ids
    refute unrelated.id in ids
  end
end
