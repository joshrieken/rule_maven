defmodule RuleMaven.GamesRetrievalTest do
  use RuleMaven.DataCase
  alias RuleMaven.Games
  alias RuleMaven.Games.Chunk

  defp published_doc(game, label, kind) do
    {:ok, d} =
      Games.create_document(%{game_id: game.id, label: label, kind: kind, full_text: "seed"})

    {:ok, d} = Games.update_document(d, %{status: "published"})
    d
  end

  defp put_chunk(doc, content, vec) do
    Repo.insert!(%Chunk{
      document_id: doc.id,
      chunk_index: 0,
      content: content,
      page_number: 1,
      embedding: Pgvector.new(vec)
    })
  end

  test "returns source metadata with each chunk" do
    {:ok, game} = Games.create_game(%{name: "Meta #{System.unique_integer([:positive])}"})
    doc = published_doc(game, "Core rules", "rulebook")
    put_chunk(doc, "[Page 1]\ndraw five cards", List.duplicate(0.1, 768))

    [chunk] =
      Games.retrieve_chunks_for_games([game.id], "cards", embedding: List.duplicate(0.1, 768))

    assert %{
             content: "[Page 1]\ndraw five cards",
             label: "Core rules",
             kind: "rulebook",
             game_id: game_id,
             game_name: _,
             document_id: _
           } = chunk

    assert game_id == game.id
  end

  test "near-duplicate chunks collapse to the higher-authority source" do
    {:ok, game} = Games.create_game(%{name: "Dedup #{System.unique_integer([:positive])}"})
    rulebook = published_doc(game, "Rulebook", "rulebook")
    guide = published_doc(game, "Learn to play", "howto")
    vec = List.duplicate(0.1, 768)
    put_chunk(rulebook, "[Page 3]\nscoring: majority wins", vec)
    put_chunk(guide, "[Page 1]\nscoring: majority wins!", vec)

    chunks = Games.retrieve_chunks_for_games([game.id], "scoring", embedding: vec, limit: 6)

    assert Enum.count(chunks, &(&1.content =~ "majority wins")) == 1
    assert Enum.find(chunks, &(&1.content =~ "majority wins")).kind == "rulebook"
  end

  test "same kind: base game beats expansion on a duplicate" do
    {:ok, base} = Games.create_game(%{name: "Base #{System.unique_integer([:positive])}"})
    {:ok, exp} = Games.create_game(%{name: "Exp #{System.unique_integer([:positive])}"})
    :ok = Games.link_expansion(exp.id, base.id)
    vec = List.duplicate(0.1, 768)
    put_chunk(published_doc(base, "Base rules", "rulebook"), "[Page 2]\nsetup: shuffle deck", vec)
    put_chunk(published_doc(exp, "Exp rules", "rulebook"), "[Page 2]\nsetup: shuffle deck.", vec)

    chunks =
      Games.retrieve_chunks_for_games([base.id, exp.id], "setup",
        embedding: vec,
        base_game_id: base.id,
        limit: 6
      )

    kept = Enum.filter(chunks, &(&1.content =~ "shuffle deck"))
    assert [%{game_id: kept_game}] = kept
    assert kept_game == base.id
  end
end
