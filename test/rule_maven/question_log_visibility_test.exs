defmodule RuleMaven.Games.QuestionLogVisibilityTest do
  use ExUnit.Case, async: true

  alias RuleMaven.Games.QuestionLog

  # "community" rows are pool-eligible and pool_tier treats them as trusted,
  # so an arbitrary client-supplied visibility would inject an unvetted answer
  # into every other user's cache.
  test "changeset rejects an unknown visibility" do
    cs =
      QuestionLog.changeset(%QuestionLog{}, %{
        question: "q",
        answer: "a",
        game_id: 1,
        visibility: "moderator"
      })

    refute cs.valid?
    assert {"is invalid", _} = cs.errors[:visibility]
  end

  test "changeset accepts the two real visibilities" do
    for vis <- ["private", "community"] do
      cs =
        QuestionLog.changeset(%QuestionLog{}, %{
          question: "q",
          answer: "a",
          game_id: 1,
          visibility: vis
        })

      assert cs.valid?, "expected #{vis} to be valid"
    end
  end
end
