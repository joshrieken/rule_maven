defmodule RuleMaven.Workers.ScoreCategoriesWorkerTest do
  @moduledoc """
  A co-op game (Horrified) has no end-game scoring, so the model answers "none"
  and `generate_score_categories/3` returns `[]`. The worker must still record
  that verdict, otherwise `Readiness.step_complete?(:score, ...)` reads the
  missing setting as unfinished and the Score pad step sits on "Pending"
  forever — re-enqueueing (and re-paying for) the same LLM call on every
  "Prepare game" run.
  """
  use RuleMaven.DataCase

  alias RuleMaven.{Readiness, Settings}
  alias RuleMaven.Workers.ScoreCategoriesWorker

  import RuleMaven.GamesFixtures

  defp mock_llm(answer) do
    Application.put_env(:rule_maven, :llm_mock, fn _body -> {:ok, %{answer: answer}} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp perform(game),
    do: ScoreCategoriesWorker.perform(%Oban.Job{id: 1, args: %{"game_id" => game.id}})

  describe "a game with no scoring categories" do
    test "records the empty verdict so the readiness step reads as done" do
      game = game_fixture(%{name: "Horrified"})
      mock_llm("none")

      assert :ok = perform(game)

      assert Settings.get("score_categories_#{game.id}") == "[]"
      assert Readiness.step_complete?(:score, game, [])
    end
  end

  describe "a game with scoring categories" do
    test "stores the categories and completes the step" do
      game = game_fixture(%{name: "Wingspan"})
      mock_llm("- Birds || One point per bird\n- Eggs || One point per egg")

      assert :ok = perform(game)

      assert [%{"label" => "Birds"}, %{"label" => "Eggs"}] =
               Jason.decode!(Settings.get("score_categories_#{game.id}"))

      assert Readiness.step_complete?(:score, game, [])
    end
  end
end
