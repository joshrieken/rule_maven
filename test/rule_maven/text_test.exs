defmodule RuleMaven.TextTest do
  use ExUnit.Case, async: true
  alias RuleMaven.Text

  describe "scrub_decorative/1" do
    test "removes filled-shape and symbol icon artifacts and tidies spacing" do
      assert Text.scrub_decorative("c) City ● Requires: 3 Ore & 2 Grain") ==
               "c) City Requires: 3 Ore & 2 Grain"

      assert Text.scrub_decorative("upgrade on the same intersection ●.") ==
               "upgrade on the same intersection."

      assert Text.scrub_decorative("A ◧ B and a ⛫ castle") == "A B and a castle"
    end

    test "strips stray emoji and variation selectors" do
      assert Text.scrub_decorative("build a settlement 🏠 here") == "build a settlement here"
    end

    test "preserves meaningful symbols and structure" do
      # arrows, bullets, dashes, quotes, newlines all survive
      assert Text.scrub_decorative("A → B") == "A → B"
      assert Text.scrub_decorative("• first\n• second") == "• first\n• second"
      assert Text.scrub_decorative("a—b “q” it’s") == "a—b “q” it’s"
      assert Text.scrub_decorative("Round Two\nOnce all players") == "Round Two\nOnce all players"
    end

    test "is idempotent" do
      once = Text.scrub_decorative("c) City ● Requires")
      assert Text.scrub_decorative(once) == once
    end

    test "handles nil" do
      assert Text.scrub_decorative(nil) == nil
    end
  end
end
