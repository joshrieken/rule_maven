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

  test "critique_grounding returns the parsed verdict map" do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok, %{answer: "VERDICT: hallucinated\nFLAGGED: Monster defeats lower Terror."}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert {:ok, %{verdict: :hallucinated, flagged_clause: "Monster defeats lower Terror."}} =
             LLM.critique_grounding(["Move the Terror Marker up one space."], "some answer")
  end

  test "critique_grounding passes through an error" do
    Application.put_env(:rule_maven, :llm_mock, fn _body -> {:error, "boom"} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert {:error, "boom"} = LLM.critique_grounding(["a quote"], "an answer")
  end
end
