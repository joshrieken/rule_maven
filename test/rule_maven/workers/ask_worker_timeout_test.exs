defmodule RuleMaven.Workers.AskWorkerTimeoutTest do
  @moduledoc """
  AskWorker.run_bounded/2 puts a hard wall-clock ceiling on a whole ask so a
  wedged LLM stream (an upstream stall that delivers no SSE chunks, so the
  per-chunk 60s deadline never fires) can't pin the Oban job — and the
  question's "Thinking..." row — forever. Pins the pass-through and timeout
  behaviour, and that the timeout error routes through the "timeout"
  classification the {:error, reason} branch keys off.
  """

  use ExUnit.Case, async: true

  alias RuleMaven.Workers.AskWorker

  test "passes the fun's return value through when it finishes in time" do
    assert {:ok, %{answer: "hi"}} =
             AskWorker.run_bounded(fn -> {:ok, %{answer: "hi"}} end, 1_000)
  end

  test "returns a timeout error when the fun overruns the cap" do
    assert {:error, reason} =
             AskWorker.run_bounded(fn ->
               Process.sleep(5_000)
               {:ok, %{answer: "too late"}}
             end, 50)

    # The word "timeout" is what the AskWorker error branch matches to flip the
    # row to the friendly "took too long" answer with error_kind "timeout".
    assert reason =~ "timeout"
  end

  test "propagates Logger.metadata into the task (llm_logs question tagging)" do
    Logger.metadata(question_log_id: 4242)

    assert 4242 =
             AskWorker.run_bounded(fn -> Logger.metadata()[:question_log_id] end, 1_000)
  end
end
