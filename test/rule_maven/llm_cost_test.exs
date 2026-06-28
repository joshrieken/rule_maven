defmodule RuleMaven.LLMCostTest do
  use RuleMaven.DataCase

  alias RuleMaven.{LLM, Users, Repo}
  alias RuleMaven.LLM.Pricing

  defp user_fixture(name) do
    {:ok, u} =
      Users.create_user(%{username: name, email: "#{name}@test.com", password: "testpass1234"})

    u
  end

  defp log(user_id, model, prompt, completion, at \\ DateTime.utc_now()) do
    Repo.insert!(%LLM.Log{
      provider: "test",
      model: model,
      operation: "ask",
      prompt_tokens: prompt,
      completion_tokens: completion,
      total_tokens: prompt + completion,
      success: true,
      user_id: user_id,
      inserted_at: DateTime.truncate(at, :second),
      updated_at: DateTime.truncate(at, :second)
    })
  end

  describe "Pricing" do
    test "matches by substring incl. provider prefix, falls back for unknown" do
      assert Pricing.rate("google/gemini-2.5-flash") == Pricing.rate("gemini-2.5-flash")
      assert {0.5, 1.5} = Pricing.rate("some-unknown-model")
    end

    test "cost combines input and output rates" do
      # gemini-2.5-flash: 0.30 in / 2.50 out per 1M
      cost = Pricing.cost("gemini-2.5-flash", 1_000_000, 1_000_000)
      assert_in_delta cost, 2.80, 0.0001
    end
  end

  describe "cost_by_user/1" do
    test "aggregates per user across models, sorted by cost desc" do
      big = user_fixture("big")
      small = user_fixture("small")

      log(big.id, "gemini-2.5-flash", 1_000_000, 1_000_000)
      log(small.id, "gemini-2.5-flash", 1000, 1000)

      [first, second] = LLM.cost_by_user(30)
      assert first.username == "big"
      assert first.cost > second.cost
      assert first.requests == 1
    end

    test "ignores rows with no user" do
      log(nil, "gemini-2.5-flash", 1000, 1000)
      assert LLM.cost_by_user(30) == []
    end
  end

  describe "user_cost_today/1" do
    test "sums today's spend, excludes older rows" do
      u = user_fixture("today")
      log(u.id, "gemini-2.5-flash", 1_000_000, 0)
      log(u.id, "gemini-2.5-flash", 1_000_000, 0, DateTime.add(DateTime.utc_now(), -2, :day))

      # Only today's 1M input tokens at $0.30/1M counts.
      assert_in_delta LLM.user_cost_today(u.id), 0.30, 0.0001
    end
  end
end
