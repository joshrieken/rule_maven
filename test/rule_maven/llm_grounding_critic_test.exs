defmodule RuleMaven.LLMGroundingCriticTest do
  use RuleMaven.DataCase

  alias RuleMaven.LLM

  test "parses a grounded verdict with no flagged clause" do
    assert LLM.parse_grounding_verdict("VERDICT: grounded") ==
             %{verdict: :grounded, flagged_clause: nil}
  end

  test "parses a hallucinated verdict with its flagged clause" do
    text = """
    VERDICT: hallucinated
    FLAGGED: Defeating a Monster lowers Terror Level.
    """

    assert LLM.parse_grounding_verdict(text) ==
             %{verdict: :hallucinated, flagged_clause: "Defeating a Monster lowers Terror Level."}
  end

  test "verdict is case/spacing tolerant" do
    assert %{verdict: :hallucinated} =
             LLM.parse_grounding_verdict("verdict:  Hallucinated\nFLAGGED: extra claim")
  end

  test "missing or unparsable verdict falls back to grounded (critic never blocks)" do
    assert %{verdict: :grounded, flagged_clause: nil} = LLM.parse_grounding_verdict("")
    assert %{verdict: :grounded, flagged_clause: nil} = LLM.parse_grounding_verdict("garbage reply")
  end
end
