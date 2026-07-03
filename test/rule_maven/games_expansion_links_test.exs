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

  describe "join-backed queries" do
    setup do
      exp = game("Promo")
      base1 = game("Ed1")
      base2 = game("Ed2")
      :ok = Games.link_expansion(exp.id, base1.id)
      :ok = Games.link_expansion(exp.id, base2.id)
      %{exp: exp, base1: base1, base2: base2}
    end

    test "expansions_for lists the expansion under every linked base", ctx do
      assert Enum.map(Games.expansions_for(ctx.base1), & &1.id) == [ctx.exp.id]
      assert Enum.map(Games.expansions_for(ctx.base2), & &1.id) == [ctx.exp.id]
    end

    test "expansion_counts counts per base", ctx do
      counts = Games.expansion_counts([ctx.base1.id, ctx.base2.id])
      assert counts[ctx.base1.id] == 1
      assert counts[ctx.base2.id] == 1
    end

    test "expansions_with_documents needs a published doc", ctx do
      assert Games.expansions_with_documents(ctx.base1) == []

      {:ok, doc} =
        Games.create_document(%{game_id: ctx.exp.id, label: "Promo rules", full_text: "some promo rules text"})

      {:ok, _} = Games.update_document(doc, %{status: "published"})
      assert Enum.map(Games.expansions_with_documents(ctx.base1), & &1.id) == [ctx.exp.id]
    end

    test "base_games_for returns all bases; base_game_for the first", ctx do
      assert Games.base_games_for(ctx.exp) |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([ctx.base1.id, ctx.base2.id])

      assert Games.base_game_for(ctx.exp).id in [ctx.base1.id, ctx.base2.id]
      assert Games.base_game_for(ctx.base1) == nil
    end

    test "list_base_games excludes linked expansions", ctx do
      ids = Games.list_base_games() |> Enum.map(& &1.id)
      assert ctx.base1.id in ids
      refute ctx.exp.id in ids
    end

    test "expansion_pull_counts counts expansions missing bgg_data per base", ctx do
      {:ok, _exp} = Games.update_game(ctx.exp, %{bgg_id: 12_345, bgg_data: nil})

      counts = Games.expansion_pull_counts([ctx.base1.id, ctx.base2.id])
      assert counts[ctx.base1.id] == 1
      assert counts[ctx.base2.id] == 1

      other_base = game("Ed3")
      other_exp = game("HasData")
      :ok = Games.link_expansion(other_exp.id, other_base.id)
      {:ok, _} = Games.update_game(other_exp, %{bgg_id: 99_999, bgg_data: "<xml/>"})

      no_pull_counts = Games.expansion_pull_counts([other_base.id])
      assert no_pull_counts[other_base.id] == nil
    end

    test "expansion_with_doc_counts counts distinct expansions with published docs per base", ctx do
      {:ok, doc1} =
        Games.create_document(%{
          game_id: ctx.exp.id,
          label: "Promo rules",
          full_text: "some promo rules text"
        })

      {:ok, _} = Games.update_document(doc1, %{status: "published"})

      {:ok, doc2} =
        Games.create_document(%{
          game_id: ctx.exp.id,
          label: "Promo rules v2",
          full_text: "more promo rules text"
        })

      {:ok, _} = Games.update_document(doc2, %{status: "published"})

      counts = Games.expansion_with_doc_counts([ctx.base1.id, ctx.base2.id])
      assert counts[ctx.base1.id] == 1
      assert counts[ctx.base2.id] == 1

      empty_base = game("Ed3")
      assert Games.expansion_with_doc_counts([empty_base.id]) == %{}
    end
  end
end
