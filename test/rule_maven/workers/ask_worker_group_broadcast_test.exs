defmodule RuleMaven.Workers.AskWorkerGroupBroadcastTest do
  @moduledoc """
  Task 9: the `:ask_complete` broadcast carries `group_id` from the
  persisted `QuestionLog` row, alongside every pre-existing key. The
  `"game:\#{game_id}"` topic is public to every viewer of the game, so this
  only asserts the id rides along — never question content.
  """
  use RuleMaven.DataCase, async: true

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.GamesFixtures
  alias RuleMaven.GroupsFixtures
  alias RuleMaven.Workers.AskWorker

  defp create_user(prefix) do
    Repo.insert!(%RuleMaven.Users.User{
      username: "#{prefix}_#{System.unique_integer([:positive])}",
      email: "#{prefix}_#{System.unique_integer([:positive])}@test.com",
      password_hash: "x"
    })
  end

  test ":ask_complete payload carries group_id and preserves existing keys" do
    game = GamesFixtures.game_fixture()
    owner = create_user("bcast_owner")
    grp = GroupsFixtures.group_fixture(owner)

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "q",
        answer: "a",
        promoted: false,
        group_id: grp.id
      })

    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    AskWorker.broadcast_complete(ql, %{tier: :fresh, faq_hit: false, pool_hit: false})

    assert_receive {:ask_complete, payload}
    assert payload.question_log_id == ql.id
    assert payload.group_id == grp.id
    assert payload.tier == :fresh
    assert payload.faq_hit == false
    assert payload.pool_hit == false
  end

  test "a non-group question broadcasts group_id: nil" do
    game = GamesFixtures.game_fixture(%{bgg_id: 9101, name: "No Group Game"})
    user = create_user("bcast_solo")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "q",
        answer: "a",
        promoted: false
      })

    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    AskWorker.broadcast_complete(ql, %{tier: :fresh})

    assert_receive {:ask_complete, payload}
    assert payload.question_log_id == ql.id
    assert payload.group_id == nil
  end
end
