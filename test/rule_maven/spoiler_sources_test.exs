defmodule RuleMaven.SpoilerSourcesTest do
  @moduledoc """
  A source document can be flagged `spoiler` (e.g. Gloomhaven's spoiler FAQ:
  locked classes, scenarios, items). Any answer citing one is a spoiler answer —
  matched by the citation's document_id, or by its source label for rows whose
  citations predate document_id resolution.
  """
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.{Document, QuestionLog}

  defp doc(game, label, spoiler) do
    Repo.insert!(%Document{
      game_id: game.id,
      label: label,
      kind: "faq",
      status: "published",
      spoiler: spoiler
    })
  end

  setup do
    game = published_game_fixture(%{name: "Spoiler Game"})
    plain = doc(game, "Official FAQ", false)
    spoil = doc(game, "Official FAQ — spoilers", true)
    %{game: game, plain: plain, spoil: spoil, index: Games.spoiler_index([game.id])}
  end

  test "index holds only the flagged documents", %{index: idx, spoil: spoil, plain: plain} do
    assert MapSet.member?(idx.ids, spoil.id)
    refute MapSet.member?(idx.ids, plain.id)
  end

  test "an answer citing a spoiler document (by id or by label) is a spoiler", %{
    index: idx,
    spoil: spoil,
    plain: plain
  } do
    by_id = %QuestionLog{citations: [%{"quote" => "q", "page" => 1, "document_id" => spoil.id}]}

    by_label = %QuestionLog{
      citations: [%{"quote" => "q", "page" => 1, "source" => "official faq — SPOILERS"}]
    }

    mixed = %QuestionLog{citations: [%{"document_id" => plain.id}, %{"document_id" => spoil.id}]}
    top = %QuestionLog{citations: [], document_id: spoil.id}

    for q <- [by_id, by_label, mixed, top], do: assert(QuestionLog.spoiler?(q, idx))
  end

  test "answers citing only non-spoiler sources are not", %{index: idx, plain: plain} do
    refute QuestionLog.spoiler?(
             %QuestionLog{citations: [%{"document_id" => plain.id, "source" => "Official FAQ"}]},
             idx
           )

    refute QuestionLog.spoiler?(%QuestionLog{citations: nil}, idx)

    refute QuestionLog.spoiler?(
             %QuestionLog{citations: [%{"source" => "Official FAQ"}]},
             Games.spoiler_index([])
           )
  end

  test "manual import can flag a document as spoiler", %{game: game} do
    {:ok, d} =
      RuleMaven.ManualImport.import(game, %{
        "label" => "Scenario spoilers",
        "kind" => "faq",
        "spoiler" => true,
        "pages" => [%{"sheet" => 1, "printed" => nil, "text" => "Scenario 19: the altar."}]
      })

    assert d.spoiler
  end
end
