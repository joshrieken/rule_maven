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

    assert %{verdict: :grounded, flagged_clause: nil} =
             LLM.parse_grounding_verdict("garbage reply")
  end

  test "critique_grounding returns the parsed verdict map" do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok, %{answer: "VERDICT: hallucinated\nFLAGGED: Monster defeats lower Terror."}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert {:ok, %{verdict: :hallucinated, flagged_clause: "Monster defeats lower Terror."}} =
             LLM.critique_grounding(["Move the Terror Marker up one space."], "some answer")
  end

  test "critique_grounding sends retrieved chunks as RULEBOOK EXCERPTS to the critic" do
    parent = self()

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      send(parent, {:llm_body, body})
      {:ok, %{answer: "VERDICT: grounded"}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert {:ok, %{verdict: :grounded}} =
             LLM.critique_grounding(["You may move into a location with a Monster."], "answer",
               sources: [
                 "[Page 5]\nMOVE\nMove your Hero along the path to an adjacent location."
               ]
             )

    assert_receive {:llm_body, body}
    user_msg = body.messages |> Enum.find(&(&1.role == "user")) |> Map.get(:content)

    assert user_msg =~ "RULEBOOK EXCERPTS:"
    assert user_msg =~ "Move your Hero along the path"
    assert user_msg =~ "CITED QUOTE(S):"
  end

  test "critique_grounding without sources omits the excerpts block (quote-only fallback)" do
    parent = self()

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      send(parent, {:llm_body, body})
      {:ok, %{answer: "VERDICT: grounded"}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert {:ok, %{verdict: :grounded}} = LLM.critique_grounding(["a quote"], "an answer")

    assert_receive {:llm_body, body}
    user_msg = body.messages |> Enum.find(&(&1.role == "user")) |> Map.get(:content)

    refute user_msg =~ "RULEBOOK EXCERPTS:"
    assert user_msg =~ "CITED QUOTE(S):"
  end

  test "critique_grounding passes through an error" do
    Application.put_env(:rule_maven, :llm_mock, fn _body -> {:error, "boom"} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert {:error, "boom"} = LLM.critique_grounding(["a quote"], "an answer")
  end
end
