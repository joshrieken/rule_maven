defmodule RuleMaven.BGGTest do
  use ExUnit.Case, async: true

  alias RuleMaven.BGG

  @sample_xml """
  <items>
    <item type="boardgame" id="123">
      <yearpublished value="2020" />
      <minplayers value="2" />
      <maxplayers value="4" />
      <playingtime value="60" />
      <image>https://example.com/img.jpg</image>
      <thumbnail>https://example.com/thumb.jpg</thumbnail>
      <statistics>
        <ratings>
          <averageweight value="2.6667" />
        </ratings>
      </statistics>
    </item>
  </items>
  """

  test "extract_weight/1 parses averageweight from raw XML" do
    assert_in_delta BGG.extract_weight(@sample_xml), 2.6667, 0.0001
  end

  test "extract_weight/1 returns nil when averageweight is missing or zero" do
    xml_without_weight = """
    <items>
      <item type="boardgame" id="123">
        <yearpublished value="2020" />
      </item>
    </items>
    """

    assert BGG.extract_weight(xml_without_weight) == nil
  end

  test "extract_weight/1 returns nil for averageweight of 0.0 (BGG's unrated sentinel)" do
    xml_zero_weight = """
    <items>
      <item type="boardgame" id="123">
        <statistics>
          <ratings>
            <averageweight value="0" />
          </ratings>
        </statistics>
      </item>
    </items>
    """

    assert BGG.extract_weight(xml_zero_weight) == nil
  end
end
