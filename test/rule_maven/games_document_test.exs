defmodule RuleMaven.GamesDocumentTest do
  use RuleMaven.DataCase
  alias RuleMaven.Games

  setup do
    {:ok, game} = Games.create_game(%{name: "Doc Test"})
    %{game: game}
  end

  test "auto-publishes clean document", %{game: game} do
    # Clean English text >500 chars should auto-publish
    text = """
    Setup: Each player receives five cards from the deck. Place the remaining
    cards in the center of the table. The youngest player goes first. Shuffle
    all remaining cards thoroughly before starting.

    Turn Structure: On your turn, draw one card and play one card. Cards have
    various effects that may modify the rules. After playing, pass the turn
    clockwise. You must announce your action before drawing additional cards.
    The maximum hand size is seven cards at all times during the game.

    Combat: When two players occupy the same space, combat begins immediately.
    Each player rolls a die and adds their strength modifier. The higher total
    wins the combat. The loser retreats to the nearest empty space.

    Winning: The first player to collect ten victory points wins the game.
    Victory points are earned by completing quests and defeating opponents.
    A player may hold at most five quests at any time during the game session.

    Additional Rules: Players cannot trade cards during combat rounds. Trading
    is only allowed during the planning phase at the start of each turn.
    """

    assert String.length(text) > 500

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Test Rulebook",
        full_text: text
      })

    assert doc.status == "published"
    assert String.length(doc.full_text) > 500
  end

  test "flags garbage text for review", %{game: game} do
    garbage = "!@#$%^&*() xyz 123 ### ??? --- ___"

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Bad OCR",
        full_text: garbage
      })

    assert doc.status == "pending_review"
  end

  test "flags short text for review", %{game: game} do
    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Too short",
        full_text: "hello"
      })

    assert doc.status == "pending_review"
  end

  test "update_document persists edited text, re-derives pages, and re-chunks", %{game: game} do
    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Rules",
        full_text: "original one\foriginal two"
      })

    assert Enum.map(doc.pages, & &1.text) == ["original one", "original two"]

    # This short doc auto-flags as pending_review; publish it so retrieval can
    # see it (only published docs are retrievable — the point under test here is
    # re-chunking on edit, not the approval gate).
    {:ok, _} = Games.approve_document(doc)

    chunks_before = Games.retrieve_chunks(game, "original") |> length()
    assert chunks_before > 0

    {:ok, updated} =
      Games.update_document(doc, %{full_text: "edited alpha\fedited beta\fedited gamma"})

    assert updated.full_text == "edited alpha\fedited beta\fedited gamma"
    assert Enum.map(updated.pages, & &1.text) == ["edited alpha", "edited beta", "edited gamma"]
    # Chunks reflect the new text, not the old (stale "original" chunks are gone).
    contents =
      Games.retrieve_chunks(game, "edited")
      |> Enum.map_join(" ", & &1.content)

    assert contents =~ "edited"
    refute contents =~ "original"
  end
end
