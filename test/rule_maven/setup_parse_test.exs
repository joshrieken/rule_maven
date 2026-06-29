defmodule RuleMaven.SetupParseTest do
  use ExUnit.Case, async: true

  alias RuleMaven.Setup

  describe "parse_sections/1" do
    test "parses plain labelled bullets" do
      content = """
      Components:
      - 1 game board
      - 60 pieces

      Steps:
      - Place the board — center of table
      - Deal 5 cards to each player
      """

      assert %{"components" => comps, "setup" => steps} = Setup.parse_sections(content)
      assert comps == ["1 game board", "60 pieces"]
      assert [%{"title" => "Place the board", "detail" => "center of table"} | _] = steps
    end

    test "tolerates markdown headers and bold item text" do
      content = """
      **Components:**
      - **1 game board**
      - 60 wooden pieces

      ## Setup Steps
      1. **Place the board** in the center of the table
      2. Shuffle the deck — deal 5 cards to each player
      """

      assert %{"components" => comps, "setup" => steps} = Setup.parse_sections(content)
      assert comps == ["1 game board", "60 wooden pieces"]
      assert Enum.map(steps, & &1["title"]) == ["Place the board in the center of the table", "Shuffle the deck"]
    end

    test "recognizes the 'Game setup' header synonym" do
      content = """
      Components needed:
      - tokens

      Game Setup:
      - Put tokens in the bag
      """

      assert %{"components" => ["tokens"], "setup" => steps} = Setup.parse_sections(content)
      assert [%{"title" => "Put tokens in the bag"}] = steps
    end

    test "does not treat a 'setup' bullet as a section header" do
      content = """
      Steps:
      - Setup the board first
      - Then deal cards
      """

      assert %{"setup" => steps} = Setup.parse_sections(content)
      assert Enum.map(steps, & &1["title"]) == ["Setup the board first", "Then deal cards"]
    end

    test "returns nil when nothing parses" do
      assert Setup.parse_sections("just some prose with no bullets or headers") == nil
    end
  end
end
