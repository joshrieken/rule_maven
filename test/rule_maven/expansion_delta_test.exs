defmodule RuleMaven.ExpansionDeltaTest do
  use RuleMaven.DataCase

  test "delta prompts are registered with their vars" do
    assert RuleMaven.Prompts.template("expansion_delta_system") =~ "expansion"

    rendered =
      RuleMaven.Prompts.render("expansion_delta", %{game_name: "Wingfans", rulebook: "TEXT"})

    assert rendered =~ "Wingfans"
    assert rendered =~ "TEXT"
    refute rendered =~ "{{"
  end

  describe "parse_sections/1" do
    test "parses the three labelled sections" do
      out = """
      COMPONENTS:
      - 15 fan tokens
      - 1 gale board

      SETUP:
      - Place the gale board — next to the main board
      - Shuffle fan tokens

      RULE CHANGES:
      - Draw 3 cards instead of 2 at the start of each round
      """

      assert %{
               "components" => ["15 fan tokens", "1 gale board"],
               "setup" => [
                 %{"title" => "Place the gale board", "detail" => "next to the main board"},
                 %{"title" => "Shuffle fan tokens", "detail" => ""}
               ],
               "rules" => ["Draw 3 cards instead of 2 at the start of each round"]
             } = RuleMaven.ExpansionDelta.parse_sections(out)
    end

    test "tolerates markdown headers and empty sections" do
      out = """
      **Components:**

      ## Setup
      - Add the new deck

      **Rule changes:**
      """

      assert %{"components" => [], "setup" => [%{"title" => "Add the new deck"}], "rules" => []} =
               RuleMaven.ExpansionDelta.parse_sections(out)
    end

    test "nil when nothing parses" do
      assert RuleMaven.ExpansionDelta.parse_sections("no sections here") == nil
    end
  end
end
