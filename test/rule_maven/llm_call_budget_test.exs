defmodule RuleMaven.LLMCallBudgetTest do
  @moduledoc """
  One ask must not be able to buy an unbounded number of LLM calls.

  Each retry/escalation mechanism caps itself at one retry, but they nest, so
  the totals multiply. `run_bounded/2`'s 180s cap bounds wall-clock, not spend,
  and the cost cap only blocks the *next* ask (it reads llm_logs rows already
  written). The per-ask budget is the only ceiling on calls per question.
  """
  use RuleMaven.DataCase

  alias RuleMaven.LLM

  setup do
    # Budget lives in the process dictionary; make sure a previous test can't
    # leak one into this process.
    Process.delete(:rm_llm_calls_remaining)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
    :ok
  end

  defp counting_mock(counter) do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      Agent.update(counter, &(&1 + 1))
      # A blank answer keeps every downstream retry path interested, so the
      # cascade tries to keep spending.
      {:ok, %{answer: "", cited_passage: nil, followups: []}}
    end)
  end

  test "an unarmed process is unlimited (non-ask callers are unaffected)" do
    assert LLM.__calls_remaining__() == nil
  end

  test "arming the budget bounds the number of calls a cascade can make" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    counting_mock(counter)

    LLM.start_call_budget(3)

    # Drive calls directly through the same chokepoint ask/5 uses.
    for _ <- 1..10 do
      LLM.chat("hi", "chat_test", max_tokens: 10)
    end

    assert Agent.get(counter, & &1) == 3, "budget must stop the 4th call onward"
  end

  test "the budget is spent down and then reports exhaustion" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    counting_mock(counter)

    LLM.start_call_budget(1)
    assert LLM.__calls_remaining__() == 1

    LLM.chat("hi", "chat_test", max_tokens: 10)
    assert LLM.__calls_remaining__() == 0

    # The next call never reaches the mock and surfaces a distinguishable error.
    assert {:error, reason} = LLM.chat("hi again", "chat_test", max_tokens: 10)
    assert reason =~ "budget"
    assert Agent.get(counter, & &1) == 1
  end

  test "ask/5 arms the budget for its own process" do
    {:ok, game} = RuleMaven.Games.create_game(%{name: "BudgetGame"})
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    counting_mock(counter)

    LLM.ask(game, "How many players?", [], [])

    # Whatever the cascade did, it cannot have exceeded the ceiling.
    remaining = LLM.__calls_remaining__()
    assert is_integer(remaining), "ask/5 must arm the budget"
    assert Agent.get(counter, & &1) <= 12
  end
end
