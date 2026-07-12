defmodule RuleMaven.FaqTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.{Faq, Games}

  describe "community stats" do
    setup do
      {:ok, game} = Games.create_game(%{name: "Test Game"})
      %{game: game}
    end

    test "community_count/1 counts only community, non-refused questions", %{game: game} do
      {:ok, _} =
        Games.log_question(%{
          game_id: game.id,
          question: "Q1",
          answer: "A1",
          visibility: "community"
        })

      {:ok, _} =
        Games.log_question(%{
          game_id: game.id,
          question: "Q2",
          answer: "A2",
          visibility: "private"
        })

      {:ok, _} =
        Games.log_question(%{
          game_id: game.id,
          question: "Q3",
          answer: "A3",
          visibility: "community",
          refused: true
        })

      assert Faq.community_count(game) == 1
    end

    test "community_count/1 includes eligible unverified pooled questions", %{game: game} do
      {:ok, _} =
        Games.log_question(%{
          game_id: game.id,
          question: "Pooled Q",
          answer: "A",
          visibility: "private",
          pooled: true,
          browsable: true
        })

      # Ineligible pooled rows don't count.
      {:ok, _} =
        Games.log_question(%{
          game_id: game.id,
          question: "Blocked Q",
          answer: "A",
          visibility: "private",
          pooled: true,
          blocked: true
        })

      {:ok, _} =
        Games.log_question(%{
          game_id: game.id,
          question: "Downvoted Q",
          answer: "A",
          visibility: "private",
          pooled: true,
          trust_score: -2.0
        })

      assert Faq.community_count(game) == 1
    end

    test "stats/0 reports total community count", %{game: game} do
      {:ok, _} =
        Games.log_question(%{
          game_id: game.id,
          question: "Q",
          answer: "A",
          visibility: "community"
        })

      assert %{community: n} = Faq.stats()
      assert n >= 1
    end
  end
end
