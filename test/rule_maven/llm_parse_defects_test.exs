defmodule RuleMaven.LLMParseDefectsTest do
  use ExUnit.Case, async: true

  alias RuleMaven.LLM

  describe "parse_defects/1 (adversarial critic reply → defect list)" do
    test "clean replies yield no defects (no needless re-transcribe)" do
      assert LLM.parse_defects("NONE") == []
      assert LLM.parse_defects("NONE.") == []
      assert LLM.parse_defects("none") == []
      assert LLM.parse_defects("  None  ") == []
      assert LLM.parse_defects("") == []
      assert LLM.parse_defects(nil) == []
      assert LLM.parse_defects("No defects found.") == []
      assert LLM.parse_defects("No issues.") == []
    end

    test "real defects are returned line by line" do
      reply = """
      MISSING: the scoring sidebar on the right
      WRONG NUMBER: says 5 victory points, image shows 6
      """

      assert LLM.parse_defects(reply) == [
               "MISSING: the scoring sidebar on the right",
               "WRONG NUMBER: says 5 victory points, image shows 6"
             ]
    end

    test "a trailing NONE line among blanks is dropped, real defects kept" do
      reply = "TABLE: dropped the second row\n\nNONE"
      assert LLM.parse_defects(reply) == ["TABLE: dropped the second row"]
    end
  end
end
