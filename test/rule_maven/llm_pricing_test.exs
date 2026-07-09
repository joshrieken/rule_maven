defmodule RuleMaven.LLM.PricingTest do
  use ExUnit.Case, async: true

  alias RuleMaven.LLM.Pricing

  test "a -lite variant does not inherit its parent model's rate" do
    # Substring matching used to hit "gemini-2.5-flash" first, pricing the
    # lite model 3-6x too high — enough to trip the cost kill switch at a
    # third of actual spend.
    assert Pricing.rate("google/gemini-2.5-flash-lite") == {0.10, 0.40}
    assert Pricing.rate("google/gemini-2.0-flash-lite") == {0.075, 0.30}
  end

  test "parent models keep their own rates" do
    assert Pricing.rate("google/gemini-2.5-flash") == {0.30, 2.50}
    assert Pricing.rate("gemini-2.0-flash") == {0.10, 0.40}
  end

  test "unknown models fall back to the default rate" do
    assert Pricing.rate("mystery-model-9000") == {0.50, 1.50}
    assert Pricing.rate(nil) == {0.50, 1.50}
  end
end
