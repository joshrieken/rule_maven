defmodule RuleMaven.GamesDocumentKindTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Games
  alias RuleMaven.Games.Document

  defp doc(attrs) do
    {:ok, game} = Games.create_game(%{name: "Kind #{System.unique_integer([:positive])}"})
    Games.create_document(Map.merge(%{game_id: game.id, label: "Rules", full_text: "text"}, attrs))
  end

  test "defaults to rulebook" do
    {:ok, d} = doc(%{})
    assert d.kind == "rulebook"
  end

  test "accepts every declared kind, rejects garbage" do
    for k <- Document.kinds() do
      assert {:ok, %{kind: ^k}} = doc(%{kind: k})
    end

    assert {:error, changeset} = doc(%{kind: "manifesto"})
    assert %{kind: ["is invalid"]} = errors_on(changeset)
  end

  test "authority order is fixed high-to-low" do
    assert Document.kinds() == ~w(errata faq rulebook scenario howto reference notes other)
    assert Document.authority("errata") < Document.authority("rulebook")
    assert Document.authority("rulebook") < Document.authority("howto")
  end
end
