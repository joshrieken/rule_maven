defmodule RuleMaven.LLMHouseRuleCheckTest do
  use ExUnit.Case, async: true

  alias RuleMaven.LLM

  test "parses strict json" do
    json = ~s({"verdict":"overrides","raw_quote":"Deal 5 cards.","note":"Changes hand size.","citations":[{"quote":"Deal 5 cards.","page":4}]})

    assert {:ok, %{verdict: "overrides", raw_quote: "Deal 5 cards.", check_note: "Changes hand size.", citations: [%{"quote" => "Deal 5 cards.", "page" => 4}]}} =
             LLM.__parse_house_rule_check__(json)
  end

  test "coerces unknown verdict to unclear and strips fences" do
    json = """
    ```json
    {"verdict":"contradicts","raw_quote":null,"note":"n","citations":[]}
    ```
    """

    assert {:ok, %{verdict: "unclear", raw_quote: nil, citations: []}} =
             LLM.__parse_house_rule_check__(json)
  end

  test "garbage returns error" do
    assert {:error, _} = LLM.__parse_house_rule_check__("not json at all")
  end
end
