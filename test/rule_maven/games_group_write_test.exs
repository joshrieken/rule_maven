defmodule RuleMaven.GamesGroupWriteTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Games

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{
            username: "#{prefix}_user",
            email: "#{prefix}_user@test.com",
            password: "password1234"
          },
          attrs
        )
      )

    user
  end

  test "log_question persists group_id and keeps visibility private" do
    game = RuleMaven.GamesFixtures.game_fixture()
    user = create_user("group_write")
    grp = RuleMaven.GroupsFixtures.group_fixture(user)

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many cards?",
        answer: "Thinking...",
        promoted: false,
        group_id: grp.id
      })

    assert q.group_id == grp.id
    assert not q.promoted
  end

  test "log_question with no group defaults group_id to nil" do
    game = RuleMaven.GamesFixtures.game_fixture(bgg_id: 43)
    user = create_user("no_group_write")

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many cards?",
        answer: "Thinking...",
        promoted: false
      })

    assert q.group_id == nil
  end
end
