defmodule RuleMaven.LLMCleanupCriticTest do
  use RuleMaven.DataCase

  alias RuleMaven.LLM

  test "parses verdict line plus defect bullets" do
    text = """
    VERDICT: junk_remains
    - GARBLE: "~~ %% §§" still present mid-page
    - HEADER: running title not removed
    """

    # Bullet markers are stripped — the lines are stored on the page and joined
    # into log messages, where a leading "- " is noise.
    assert LLM.parse_critic_verdict(text) == %{
             verdict: :junk_remains,
             defects: [
               ~s(GARBLE: "~~ %% §§" still present mid-page),
               "HEADER: running title not removed"
             ]
           }
  end

  test "verdict is case/spacing tolerant" do
    assert %{verdict: :content_lost} =
             LLM.parse_critic_verdict("verdict:  Content_Lost\n- DROPPED: setup step 3")
  end

  test "faithful verdict with NONE yields no defects" do
    assert LLM.parse_critic_verdict("VERDICT: faithful\nNONE") == %{
             verdict: :faithful,
             defects: []
           }
  end

  test "missing verdict line falls back to faithful (critic never blocks)" do
    assert %{verdict: :faithful} = LLM.parse_critic_verdict("- DROPPED: something")
    assert %{verdict: :faithful} = LLM.parse_critic_verdict("")
  end

  test "critique_cleanup returns the parsed verdict map" do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok, %{answer: "VERDICT: content_lost\n- DROPPED: the tiebreaker rule"}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert {:ok, %{verdict: :content_lost, defects: ["DROPPED: the tiebreaker rule"]}} =
             LLM.critique_cleanup("raw text", "cleaned text")
  end
end
