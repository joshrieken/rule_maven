defmodule Mix.Tasks.RuleMaven.BackfillWeightTest do
  use RuleMaven.DataCase

  alias RuleMaven.Games

  @sample_xml """
  <items>
    <item type="boardgame" id="1">
      <statistics>
        <ratings>
          <averageweight value="3.14" />
        </ratings>
      </statistics>
    </item>
  </items>
  """

  test "backfills weight from cached bgg_data, skipping already-set rows" do
    {:ok, needs_backfill} =
      Games.create_game(%{name: "Needs Backfill", bgg_id: 1, bgg_data: @sample_xml})

    {:ok, already_set} =
      Games.create_game(%{
        name: "Already Set",
        bgg_id: 2,
        bgg_data: @sample_xml,
        weight: 1.0
      })

    {:ok, no_cache} = Games.create_game(%{name: "No Cache", bgg_id: 3})

    Mix.Tasks.RuleMaven.BackfillWeight.run([])

    assert_in_delta Games.get_game!(needs_backfill.id).weight, 3.14, 0.001
    assert Games.get_game!(already_set.id).weight == 1.0
    assert Games.get_game!(no_cache.id).weight == nil
  end
end
