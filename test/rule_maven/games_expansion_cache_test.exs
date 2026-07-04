defmodule RuleMaven.GamesExpansionCacheTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.QuestionLog

  defp game(name \\ "ExpCache") do
    {:ok, g} = Games.create_game(%{name: "#{name} #{System.unique_integer([:positive])}"})
    g
  end

  describe "expansion_ids on questions_log" do
    test "defaults to [] and persists a cast list" do
      g = game()

      {:ok, plain} = Games.log_question(%{game_id: g.id, question: "q", answer: "a"})
      assert Repo.get!(QuestionLog, plain.id).expansion_ids == []

      {:ok, tagged} =
        Games.log_question(%{game_id: g.id, question: "q2", answer: "a2", expansion_ids: [7, 3]})

      assert Repo.get!(QuestionLog, tagged.id).expansion_ids == [7, 3]
    end
  end
end
