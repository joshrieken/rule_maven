defmodule RuleMaven.LLMSavingsTest do
  use RuleMaven.DataCase, async: true

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
    test "writes a cache_hit row using the estimator" do
      assert :ok = Savings.record_cache_hit("ask", nil, nil)
      row = Repo.one(from s in Savings, where: s.kind == "cache_hit")
      assert row.operation == "ask"
      assert row.estimated_tokens > 0
      assert row.estimated_usd > 0.0
    end
  end

  describe "record_call_savings/3 (prompt_cache)" do
    alias RuleMaven.{LLM, Repo}

    test "records a prompt_cache row when cached tokens are present" do
      usage = %{prompt: 5000, completion: 200, total: 5200, cached: 4000}

      assert :ok =
               LLM.record_call_savings(
                 "google/gemini-2.5-flash",
                 [operation: "ask", game_id: nil],
                 usage
               )

      row = Repo.one(from s in Savings, where: s.kind == "prompt_cache")
      assert row.estimated_tokens == 4000
      assert row.estimated_usd > 0.0
    end

    test "no prompt_cache row when there are no cached tokens" do
      usage = %{prompt: 5000, completion: 200, total: 5200, cached: 0}
      assert :ok = LLM.record_call_savings("google/gemini-2.5-flash", [operation: "ask"], usage)
      assert Repo.one(from s in Savings, where: s.kind == "prompt_cache") == nil
    end

    test "nil usage writes no prompt_cache row and returns :ok" do
      assert :ok =
               RuleMaven.LLM.record_call_savings(
                 "google/gemini-2.5-flash",
                 [operation: "ask"],
                 nil
               )

      assert Repo.one(from s in Savings, where: s.kind == "prompt_cache") == nil
    end
  end

  describe "record_call_savings/3 (cheap_route)" do
    alias RuleMaven.{LLM, Settings, Repo}

    test "records cheap_route when the call ran on the cheap model" do
      Settings.put("llm_cheap_model_openrouter", "google/gemini-2.0-flash")
      cheap = LLM.model(:cheap)
      refute cheap == LLM.model(:default)

      usage = %{prompt: 10_000, completion: 500, total: 10_500, cached: 0}
      assert :ok = LLM.record_call_savings(cheap, [operation: "suggest_questions"], usage)

      row = Repo.one(from s in Savings, where: s.kind == "cheap_route")
      assert row.operation == "suggest_questions"
      # default (gemini-2.5-flash) costs more than cheap (gemini-2.0-flash):
      assert row.estimated_usd > 0.0
    end

    test "no cheap_route when the call ran on the default model" do
      usage = %{prompt: 10_000, completion: 500, total: 10_500, cached: 0}
      assert :ok = LLM.record_call_savings(LLM.model(:default), [operation: "ask"], usage)
      assert Repo.one(from s in Savings, where: s.kind == "cheap_route") == nil
    end
  end

  describe "estimate_avoided/2" do
    alias RuleMaven.LLM
    alias RuleMaven.Repo

    defp log!(op, p, c) do
      Repo.insert!(%LLM.Log{
        provider: "test",
        model: "google/gemini-2.5-flash",
        operation: op,
        prompt_tokens: p,
        completion_tokens: c,
        total_tokens: p + c,
        success: true
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

  describe "summary/1" do
    test "headline excludes cheap_route" do
      Savings.record("cache_hit", %{operation: "ask", estimated_tokens: 100, estimated_usd: 0.10})

      Savings.record("prompt_cache", %{
        operation: "ask",
        estimated_tokens: 50,
        estimated_usd: 0.05
      })

      Savings.record("cheap_route", %{
        operation: "suggest_questions",
        estimated_tokens: 999,
        estimated_usd: 9.99
      })

      s = Savings.summary(30)
      assert_in_delta s.headline_usd, 0.15, 0.0001
      assert s.headline_tokens == 150
      kinds = Map.new(s.by_kind, &{&1.kind, &1})
      # cheap_route is reported in by_kind but excluded from the headline total
      assert kinds["cheap_route"].usd == 9.99
      assert s.headline_usd < 1.0
    end
  end
end
