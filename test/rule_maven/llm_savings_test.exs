defmodule RuleMaven.LLMSavingsTest do
  use RuleMaven.DataCase

  import Ecto.Query

  alias RuleMaven.LLM.Savings
  alias RuleMaven.Repo

  describe "record/2" do
    test "inserts a savings row" do
      assert :ok =
               Savings.record("cache_hit", %{
                 operation: "ask",
                 estimated_tokens: 1234,
                 estimated_usd: 0.0042,
                 model: "google/gemini-2.5-flash"
               })

      row = Repo.one(Savings)
      assert row.kind == "cache_hit"
      assert row.operation == "ask"
      assert row.estimated_tokens == 1234
      assert row.estimated_usd == 0.0042
    end

    test "record never raises on bad input and returns :ok" do
      assert :ok = Savings.record("cache_hit", %{estimated_tokens: "not-an-int"})
    end
  end

  describe "record_cache_hit/3" do
    alias RuleMaven.Repo

    test "writes a cache_hit row using the estimator" do
      assert :ok = Savings.record_cache_hit("ask", nil, nil)
      row = Repo.one(from s in Savings, where: s.kind == "cache_hit")
      assert row.operation == "ask"
      assert row.estimated_tokens > 0
      assert row.estimated_usd > 0.0
    end
  end

  describe "estimate_avoided/2" do
    alias RuleMaven.LLM
    alias RuleMaven.Repo

    defp log!(op, p, c) do
      Repo.insert!(%LLM.Log{
        provider: "test", model: "google/gemini-2.5-flash", operation: op,
        prompt_tokens: p, completion_tokens: c, total_tokens: p + c, success: true
      })
    end

    test "averages recent same-operation history" do
      log!("ask", 1000, 100)
      log!("ask", 3000, 300)
      est = Savings.estimate_avoided("ask", nil)
      assert est.tokens == 2200
      assert est.usd > 0.0
    end

    test "falls back to a constant when there is no history" do
      est = Savings.estimate_avoided("ask", nil)
      assert est.tokens > 0
      assert est.usd > 0.0
    end
  end
end
