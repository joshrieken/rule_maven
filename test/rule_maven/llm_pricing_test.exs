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

  # The escalate model is a Claude model, and the table had no Claude entry at
  # all — so every refusal escalation was priced at @default_rate, roughly a
  # sixth of the truth. On 2026-07-13 one Sonnet escalation billed $0.326 (31% of
  # the day's whole spend) and would have been logged at ~$0.05. The cost
  # dashboard AND the budget cap read these rates, so the priciest model in the
  # pipeline was the one they under-counted worst.
  describe "Anthropic models (the escalate path) are priced" do
    test "claude-sonnet-5 resolves to its real rate, not the default" do
      assert Pricing.rate("anthropic/claude-sonnet-5") == {3.00, 15.00}
      refute Pricing.rate("anthropic/claude-sonnet-5") == {0.50, 1.50}
    end

    test "the bare id resolves too" do
      assert Pricing.rate("claude-sonnet-5") == {3.00, 15.00}
    end

    test "opus and haiku are distinct from sonnet" do
      assert Pricing.rate("anthropic/claude-opus-4.8") == {15.00, 75.00}
      assert Pricing.rate("anthropic/claude-haiku-4-5") == {1.00, 5.00}
    end

    test "a real escalated ask is priced ~6x the old default" do
      # ~100k prompt tokens, the shape of the call that actually billed $0.326.
      sonnet = Pricing.cost("anthropic/claude-sonnet-5", 100_000, 500)
      default = Pricing.cost("mystery-model-9000", 100_000, 500)

      assert_in_delta sonnet, 0.3075, 0.001
      assert sonnet > default * 5
    end
  end
end
