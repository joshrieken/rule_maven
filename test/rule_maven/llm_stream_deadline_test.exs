defmodule RuleMaven.LLMStreamDeadlineTest do
  use ExUnit.Case, async: false

  alias RuleMaven.LLM

  # sse_into_step/4 is the per-chunk callback for a streaming answer call. Its
  # job beyond re-assembling SSE is to enforce a wall-clock ceiling: Req's
  # receive_timeout is only an IDLE timeout, so a response that keeps trickling
  # chunks would otherwise pin the ask pipeline forever (the "Thinking…" hang).

  setup do
    Process.delete(:llm_sse_state)
    Process.delete(:llm_sse_abort)
    Process.put(:llm_sse_state, LLM.__new_sse_state__())

    on_exit(fn ->
      Process.delete(:llm_sse_state)
      Process.delete(:llm_sse_abort)
    end)

    :ok
  end

  defp resp_200, do: %{status: 200, body: ""}
  # Streaming ask always targets a logged question — mirror that (nil is never
  # passed on the streaming path in production).
  defp stream_to, do: %{game_id: -1, question_log_id: -1}

  # Feed a raw SSE chunk through the callback with the deadline far out.
  defp feed_raw(chunk) do
    future = System.monotonic_time(:millisecond) + 60_000
    LLM.__sse_into_step__(future, {:req, resp_200()}, chunk, stream_to())
  end

  # A visible-answer content delta.
  defp feed(text),
    do: feed_raw("data: {\"choices\":[{\"delta\":{\"content\":#{Jason.encode!(text)}}}]}\n\n")

  test "keeps consuming (:cont) while the deadline is in the future" do
    assert {:cont, {:req, %{status: 200}}} = feed("Roll the d20.")
    refute Process.get(:llm_sse_abort)
  end

  test "halts with :timeout once the wall-clock deadline has passed" do
    past = System.monotonic_time(:millisecond) - 1
    chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"more\"}}]}\n\n"

    assert {:halt, {:req, %{status: 200}}} =
             LLM.__sse_into_step__(past, {:req, resp_200()}, chunk, stream_to())

    assert Process.get(:llm_sse_abort) == :timeout
  end

  test "halts with :runaway_answer when visible answer text blows past the cap" do
    # Open the answer field, then flood it well past @answer_content_cap (6000).
    assert {:cont, _} = feed(~s({"answer": "))
    assert {:halt, _} = feed(String.duplicate("x", 7_000))
    assert Process.get(:llm_sse_abort) == :runaway_answer
  end

  test "halts with :reasoning_stall when bytes flood but the answer never opens" do
    # Reasoning tokens arrive as non-content deltas: raw grows past
    # @answer_reasoning_stall_bytes (16_000) while `content` stays empty, so the
    # "answer" field never opens.
    reasoning = String.duplicate("z", 20_000)
    chunk = "data: {\"choices\":[{\"delta\":{\"reasoning\":#{Jason.encode!(reasoning)}}}]}\n\n"

    assert {:halt, _} = feed_raw(chunk)
    assert Process.get(:llm_sse_abort) == :reasoning_stall
  end

  test "a normal answer that opens the field is NOT flagged a stall" do
    assert {:cont, _} = feed(~s({"answer": "A perfectly reasonable, complete answer."))
    refute Process.get(:llm_sse_abort)
  end
end
