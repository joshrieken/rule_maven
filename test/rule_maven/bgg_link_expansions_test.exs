defmodule RuleMaven.BGGLinkExpansionsTest do
  use RuleMaven.DataCase
  alias RuleMaven.{BGG, Games}

  defp game(name, bgg_id) do
    {:ok, g} =
      Games.create_game(%{name: "#{name} #{System.unique_integer([:positive])}", bgg_id: bgg_id})
    g
  end

  test "inbound links attach the expansion to every matched base" do
    exp = game("Promo", 111)
    ed1 = game("Ed1", 222)
    ed2 = game("Ed2", 333)

    :ok =
      BGG.link_expansions(exp, [
        %{id: 222, value: "Ed1", inbound: "true"},
        %{id: 333, value: "Ed2", inbound: "true"},
        %{id: 999, value: "Not imported", inbound: "true"}
      ])

    assert Enum.sort(Games.base_ids_for(exp.id)) == Enum.sort([ed1.id, ed2.id])
  end

  test "outbound links attach matched expansions to this base" do
    base = game("Base", 444)
    exp = game("Exp", 555)

    :ok = BGG.link_expansions(base, [%{id: 555, value: "Exp", inbound: "false"}])

    assert Games.base_ids_for(exp.id) == [base.id]
  end

  test "re-linking is idempotent" do
    exp = game("Promo", 666)
    base = game("Base", 777)
    links = [%{id: 777, value: "Base", inbound: "true"}]

    :ok = BGG.link_expansions(exp, links)
    :ok = BGG.link_expansions(exp, links)

    assert Games.base_ids_for(exp.id) == [base.id]
  end
end
