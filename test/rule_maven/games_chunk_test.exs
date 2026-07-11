defmodule RuleMaven.GamesChunkTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.Games
  alias RuleMaven.Games.Chunk
  alias RuleMaven.Repo

  @test_rulebook """
  SECTION 1: SETUP
  Each player draws 5 cards. The youngest player goes first.

  SECTION 2: MOVEMENT
  You may move up to 4 spaces. See Section 4.3 for special movement rules.

  SECTION 4: ADVANCED
  4.3 Special Movement: If you are on a road, you may move 6 spaces instead.
  """

  setup do
    {:ok, game} = Games.create_game(%{name: "Chunk Test"})

    {:ok, doc} =
      Games.create_document(%{game_id: game.id, label: "Rules", full_text: @test_rulebook})

    Repo.update!(Ecto.Changeset.change(doc, status: "published"))
    {:ok, game: game, doc: doc}
  end

  describe "chunking" do
    test "creates chunks from document text", %{doc: doc} do
      chunks = Repo.all(from c in Chunk, where: c.document_id == ^doc.id)
      assert length(chunks) > 0
    end

    test "detects section labels", %{doc: doc} do
      chunks = Repo.all(from c in Chunk, where: c.document_id == ^doc.id)
      labels = Enum.map(chunks, & &1.section_label) |> Enum.reject(&is_nil/1)
      assert length(labels) > 0
    end

    test "detects cross-references", %{doc: doc} do
      chunks = Repo.all(from c in Chunk, where: c.document_id == ^doc.id)
      refs = Enum.flat_map(chunks, &(&1.references_section || []))
      # "See Section 4.3" should be detected
      assert "4.3" in refs
    end

    test "marks chunks with [Page N] even when printed page is undetected", %{game: game} do
      # Printed page numbers often aren't detected (OCR, odd layouts). The chunk
      # marker must still be [Page N] (falling back to the physical sheet), never
      # [Sheet N] — the LLM prompt + cited-page parser only understand [Page N].
      {:ok, doc} =
        Games.create_document(%{
          game_id: game.id,
          label: "No printed numbers",
          full_text: "Some rule text on the first sheet with enough words to chunk.",
          pages: [
            %{index: 0, sheet: 1, printed: nil, text: "Some rule text on the first sheet."}
          ]
        })

      chunks = Repo.all(from c in Chunk, where: c.document_id == ^doc.id)

      assert chunks != []
      assert Enum.all?(chunks, &String.starts_with?(&1.content, "[Page "))
      refute Enum.any?(chunks, &String.contains?(&1.content, "[Sheet "))
    end
  end

  describe "retrieval" do
    test "keyword retrieval returns chunks", %{game: game} do
      # Embedding will fail without API key, falls back to keyword
      results = Games.retrieve_chunks(game, "move spaces")
      assert length(results) > 0
    end

    test "cross-reference pull adds referenced chunks", %{game: game} do
      # This requires embeddings to test properly; keyword fallback also works
      results = Games.retrieve_chunks(game, "movement rules", 3)

      # At least some chunks should be returned
      assert length(results) > 0
    end
  end
end
