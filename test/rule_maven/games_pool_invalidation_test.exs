defmodule RuleMaven.GamesPoolInvalidationTest do
  use RuleMaven.DataCase

  import Ecto.Query
  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.QuestionLog

  defp game, do: elem(Games.create_game(%{name: "Pool #{System.unique_integer([:positive])}"}), 1)

  defp pooled_q(game, attrs) do
    {:ok, q} =
      Games.log_question(Map.merge(%{game_id: game.id, question: "q", answer: "a"}, attrs))

    {1, _} =
      Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id), set: Map.to_list(attrs))

    Repo.get!(QuestionLog, q.id)
  end

  describe "chunk_document uses effective (cleaned) text" do
    test "cleaned page text reaches the chunks, not the original" do
      game = game()

      {:ok, doc} =
        Games.create_document(%{
          game_id: game.id,
          label: "Rules",
          full_text: "original alpha text here"
        })

      Games.set_page_cleaned(doc.id, 0, "CLEANED alpha text here")
      Games.get_document!(doc.id) |> Games.chunk_document()

      contents =
        Repo.all(from c in RuleMaven.Games.Chunk, where: c.document_id == ^doc.id, select: c.content)
        |> Enum.join("\n")

      assert contents =~ "CLEANED"
      refute contents =~ "original alpha"
    end
  end

  describe "invalidate_pool/1" do
    test "demotes auto-pooled rows, leaves community rows" do
      game = game()
      auto = pooled_q(game, %{pooled: true})
      community = pooled_q(game, %{pooled: true, visibility: "community"})

      assert Games.invalidate_pool(game.id) == 2

      refute Repo.get!(QuestionLog, auto.id).pooled
      # community visibility is left able to serve from the pool query
      assert Repo.get!(QuestionLog, community.id).visibility == "community"
    end

    test "create/update/delete document invalidate the pool" do
      game = game()
      q = pooled_q(game, %{pooled: true})

      # create a second document → invalidates
      {:ok, doc} =
        Games.create_document(%{game_id: game.id, label: "R", full_text: "alpha beta gamma"})

      refute Repo.get!(QuestionLog, q.id).pooled

      # re-pool, then a content edit invalidates again
      Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id), set: [pooled: true])
      {:ok, _} = Games.update_document(doc, %{full_text: "totally different text now"})
      refute Repo.get!(QuestionLog, q.id).pooled
    end
  end
end
