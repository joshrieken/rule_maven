defmodule RuleMaven.LLMSharedBudgetTest do
  @moduledoc """
  Extraction and cleanup fan their pages out over Task.async_stream. A budget
  held in the process dictionary as a plain integer would be invisible to those
  children, so every page would silently get its own full allowance — which is
  the opposite of a per-document cap. The budget is therefore a shared :atomics
  ref that children adopt.
  """
  use RuleMaven.DataCase

  alias RuleMaven.LLM

  setup do
    Process.delete(:rm_llm_calls_remaining)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
    :ok
  end

  defp counting_mock(counter) do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      Agent.update(counter, &(&1 + 1))
      {:ok, %{answer: "ok", cited_passage: nil, followups: []}}
    end)
  end

  test "children that adopt the handle spend from one shared allowance" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    counting_mock(counter)

    LLM.start_call_budget(5)
    budget = LLM.call_budget_handle()

    # 10 pages, one call each, against a budget of 5.
    1..10
    |> Task.async_stream(
      fn _page ->
        LLM.adopt_call_budget(budget)
        LLM.chat("system", "user", raw: true, operation: "shared_budget_test")
      end,
      max_concurrency: 8,
      timeout: :infinity
    )
    |> Stream.run()

    assert Agent.get(counter, & &1) == 5,
           "the shared budget must cap total calls across all child processes"

    assert LLM.budget_exceeded?(budget)
  end

  test "budget_exceeded? distinguishes 'fit exactly' from 'was denied'" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    counting_mock(counter)

    LLM.start_call_budget(2)
    LLM.chat("s", "u", raw: true, operation: "fit_test")
    LLM.chat("s", "u", raw: true, operation: "fit_test")

    assert Agent.get(counter, & &1) == 2
    assert LLM.__calls_remaining__() == 0
    refute LLM.budget_exceeded?(), "spending exactly the budget is not an overrun"

    LLM.chat("s", "u", raw: true, operation: "fit_test")
    assert LLM.budget_exceeded?(), "a refused call is an overrun"
    assert Agent.get(counter, & &1) == 2, "the refused call must not reach the model"
  end

  test "an unarmed process is unlimited and never reports an overrun" do
    assert LLM.call_budget_handle() == nil
    refute LLM.budget_exceeded?()
    assert LLM.adopt_call_budget(nil) == :ok
  end

  test "remaining does not drift arbitrarily negative under repeated denials" do
    counting_mock(elem(Agent.start_link(fn -> 0 end), 1))
    LLM.start_call_budget(1)

    for _ <- 1..4, do: LLM.chat("s", "u", raw: true, operation: "drift_test")

    assert LLM.__calls_remaining__() == 0
    assert LLM.budget_exceeded?()
  end
end
