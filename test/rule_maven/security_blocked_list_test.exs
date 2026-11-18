defmodule RuleMaven.SecurityBlockedListTest do
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures

  alias RuleMaven.{Games, Security}

  test "the blocked list is capped newest-first; blocked_count is the true total" do
    game = game_fixture()

    for n <- 1..3 do
      {:ok, _} =
        Games.log_question(%{
          game_id: game.id,
          question: "Blocked #{n}?",
          answer: "-",
          blocked: true
        })
    end

    {:ok, _} = Games.log_question(%{game_id: game.id, question: "Fine?", answer: "-"})

    assert Security.blocked_count() == 3
    assert length(Security.list_blocked_questions()) == 3
    assert length(Security.list_blocked_questions(2)) == 2
    assert Security.max_blocked() == 200
  end
end
