defmodule RuleMaven.LLMTruncatedAnswerRetryTest do
  use RuleMaven.DataCase, async: false

  alias RuleMaven.LLM

  # A truncated/incomplete answer stream (provider dropped the connection, or
  # the JSON was cut off mid-string) must NOT flow into the citation guard,
  # which would strip its missing citations and fabricate a "rulebook does not
  # cover this" refusal. Instead it is retried once, then surfaced as a
  # retryable error so AskWorker re-runs the ask rather than storing a false
  # refusal.

  describe "answer_truncated?/1" do
    test "flags an explicit length/max_tokens finish_reason" do
      assert LLM.__answer_truncated__(%{finish_reason: "length", answer: "x", raw_response: ""})
      assert LLM.__answer_truncated__(%{finish_reason: "max_tokens", answer: "x", raw_response: ""})
    end

    test "flags an unclosed JSON object even when finish_reason is absent" do
      # The exact shape of the real Catan false-refusal: verdict opened, answer
      # cut off mid-string, no closing quote or brace.
      partial = ~s({"verdict": "info", "answer": "Specific terrain hexes produce the following)
      assert LLM.__answer_truncated__(%{finish_reason: nil, answer: partial, raw_response: partial})
    end

    test "passes a complete JSON answer through untouched" do
      whole = ~s({"verdict":"info","answer":"Forest produces lumber.","citations":[]})
      refute LLM.__answer_truncated__(%{finish_reason: "stop", answer: "Forest produces lumber.", raw_response: whole})
      refute LLM.__answer_truncated__(%{finish_reason: nil, answer: "ok", raw_response: whole})
    end

    test "does not flag non-JSON raw payloads (raw: true callers)" do
      refute LLM.__answer_truncated__(%{finish_reason: "stop", answer: "plain prose", raw_response: "plain prose"})
    end
  end

  describe "maybe_retry_truncated_answer/3" do
    test "retries once with a nonce and returns the fresh result" do
      test_pid = self()

      Application.put_env(:rule_maven, :llm_mock, fn body ->
        send(test_pid, {:mock_called, body})

        {:ok,
         %{
           finish_reason: "stop",
           answer: "Forest produces lumber.",
           raw_response: ~s({"verdict":"info","answer":"Forest produces lumber.","citations":[]}),
           citations: []
         }}
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      body = %{model: "m", max_tokens: 2048, messages: [%{role: "user", content: "q"}]}

      truncated =
        {:ok, %{finish_reason: nil, answer: ~s({"answer": "partial), raw_response: ~s({"answer": "partial)}}

      result = LLM.__maybe_retry_truncated_answer__(truncated, body, operation: "ask")

      assert {:ok, %{answer: "Forest produces lumber."}} = result

      assert_received {:mock_called, retried}
      # A cache-busting nonce is appended on a USER turn (same reasoning as the
      # stalled-stream retry).
      assert length(retried.messages) == length(body.messages) + 1
      assert List.last(retried.messages).role == "user"
    end

    test "surfaces a retryable error when the retry is still truncated" do
      Application.put_env(:rule_maven, :llm_mock, fn _body ->
        {:ok, %{finish_reason: "length", answer: ~s({"answer": "still cut), raw_response: ~s({"answer": "still cut)}}
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      body = %{model: "m", max_tokens: 2048, messages: [%{role: "user", content: "q"}]}

      truncated =
        {:ok, %{finish_reason: "length", answer: ~s({"answer": "partial), raw_response: ~s({"answer": "partial)}}

      assert {:error, reason} =
               LLM.__maybe_retry_truncated_answer__(truncated, body, operation: "ask")

      assert reason =~ "truncat"
    end

    test "does not retry a truncation that already retried (no loop)" do
      Application.put_env(:rule_maven, :llm_mock, fn _ -> flunk("must not re-call the model") end)
      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      truncated =
        {:ok, %{finish_reason: "length", answer: ~s({"answer": "partial), raw_response: ~s({"answer": "partial)}}

      assert {:error, _} =
               LLM.__maybe_retry_truncated_answer__(truncated, %{messages: []},
                 truncation_retried: true
               )
    end

    test "passes a healthy result straight through untouched" do
      Application.put_env(:rule_maven, :llm_mock, fn _ -> flunk("must not call the model") end)
      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      ok =
        {:ok,
         %{
           finish_reason: "stop",
           answer: "Forest produces lumber.",
           raw_response: ~s({"answer":"Forest produces lumber."})
         }}

      assert LLM.__maybe_retry_truncated_answer__(ok, %{messages: []}, operation: "ask") == ok
    end
  end
end
