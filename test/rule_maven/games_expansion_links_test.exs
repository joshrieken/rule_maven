defmodule RuleMaven.GamesExpansionLinksTest do
  use RuleMaven.DataCase
  alias RuleMaven.Games

  defp game(name) do
    {:ok, g} = Games.create_game(%{name: "#{name} #{System.unique_integer([:positive])}"})
    g
  end

  test "link_expansion is idempotent and supports multiple bases" do
    exp = game("Promo")
    base1 = game("Ed1")
    base2 = game("Ed2")

    :ok = Games.link_expansion(exp.id, base1.id)
    :ok = Games.link_expansion(exp.id, base1.id)
    :ok = Games.link_expansion(exp.id, base2.id)

    assert Enum.sort(Games.base_ids_for(exp.id)) == Enum.sort([base1.id, base2.id])
    assert Games.expansion?(exp.id)
    refute Games.expansion?(base1.id)
  end

  test "unlink_expansion removes one pair only" do
    exp = game("Promo")
    base1 = game("Ed1")
    base2 = game("Ed2")
    :ok = Games.link_expansion(exp.id, base1.id)
    :ok = Games.link_expansion(exp.id, base2.id)

    :ok = Games.unlink_expansion(exp.id, base1.id)

    assert Games.base_ids_for(exp.id) == [base2.id]
  end

  test "deleting a base game cascades its links but not the expansion" do
    exp = game("Promo")
    base = game("Ed1")
    :ok = Games.link_expansion(exp.id, base.id)

    {:ok, _} = Games.delete_game(base)

    assert Games.base_ids_for(exp.id) == []
    assert Games.get_game(exp.id)
  end

  test "migration backfilled existing parent_game_id rows" do
    exp = game("Legacy")
    base = game("Base")
    {:ok, exp} = Games.update_game(exp, %{parent_game_id: base.id})
    # Simulate what the backfill does for pre-existing rows.
    :ok = Games.link_expansion(exp.id, base.id)
    assert Games.base_ids_for(exp.id) == [base.id]
  end
end
