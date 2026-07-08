defmodule RuleMaven.LLMStalledStreamRetryTest do
  use RuleMaven.DataCase, async: false

  alias RuleMaven.LLM

  # A stalled/runaway answer stream (chiefly a poisoned proxy cache entry
  # replaying a reasoning-only stream) is retried ONCE with a cache-busting
  # nonce, which forces a cache miss and a genuine new generation.

  test "flags reasoning_stall and runaway, but not a genuine timeout" do
    assert LLM.__stalled_stream_error__({:error, "HTTP error: :reasoning_stall"})
    assert LLM.__stalled_stream_error__({:error, "HTTP error: :runaway_answer"})
    refute LLM.__stalled_stream_error__({:error, "HTTP error: :timeout"})
    refute LLM.__stalled_stream_error__({:ok, %{answer: "fine"}})
  end

  test "retries once with a nonce and returns the fresh result" do
    test_pid = self()

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      send(test_pid, {:mock_called, body})
      {:ok, %{finish_reason: "stop", answer: "fresh answer"}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    body = %{model: "m", max_tokens: 2048, messages: [%{role: "user", content: "q"}]}

    result =
      LLM.__maybe_retry_stalled_stream__(
        {:error, "HTTP error: :reasoning_stall"},
        body,
        operation: "ask"
      )

    assert {:ok, %{answer: "fresh answer"}} = result

    assert_received {:mock_called, retried}
    # A nonce system message was appended, so the messages array is distinct.
    assert length(retried.messages) == length(body.messages) + 1
    assert List.last(retried.messages).role == "system"
  end

  test "does not retry a stall that already retried (no loop)" do
    Application.put_env(:rule_maven, :llm_mock, fn _ -> flunk("must not re-call the model") end)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    err = {:error, "HTTP error: :reasoning_stall"}
    assert LLM.__maybe_retry_stalled_stream__(err, %{messages: []}, stream_retried: true) == err
  end

  test "passes a healthy result straight through untouched" do
    ok = {:ok, %{answer: "already good"}}
    assert LLM.__maybe_retry_stalled_stream__(ok, %{messages: []}, operation: "ask") == ok
  end
end
