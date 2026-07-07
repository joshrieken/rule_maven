defmodule RuleMaven.LLMCallTraceTest do
  @moduledoc """
  Per-question LLM call trace: llm_logs rows carry the `question_log_id` the
  process is working on (set via Logger.metadata by AskWorker et al — see
  LLM.current_question_log_id/0), and `LLM.calls_for_question/1` returns the
  chronological trace + totals that power the admin panel.
  """

  use RuleMaven.DataCase

  alias RuleMaven.{Games, LLM, Repo}
  alias RuleMaven.LLM.{Log, Pricing}
  alias RuleMaven.Workers.AskWorker

  defp mock_llm(fun) do
    Application.put_env(:rule_maven, :llm_mock, fun)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp last_log(operation) do
    Repo.one(
      from l in Log,
        where: l.operation == ^operation,
        order_by: [desc: l.id],
        limit: 1
    )
  end

  describe "log_llm question attribution" do
    test "picks up question_log_id from Logger.metadata" do
      mock_llm(fn _body -> {:ok, %{answer: "yes"}} end)
      Logger.metadata(question_log_id: 4242)
      on_exit(fn -> Logger.metadata(question_log_id: nil) end)

      {:ok, _} = LLM.chat("hi", "trace_meta_test", operation: "trace_meta_test")

      assert last_log("trace_meta_test").question_log_id == 4242
    end

    test "explicit opt wins over metadata" do
      mock_llm(fn _body -> {:ok, %{answer: "yes"}} end)
      Logger.metadata(question_log_id: 4242)
      on_exit(fn -> Logger.metadata(question_log_id: nil) end)

      {:ok, _} =
        LLM.chat("hi", "trace_opt_test",
          operation: "trace_opt_test",
          question_log_id: 777
        )

      assert last_log("trace_opt_test").question_log_id == 777
    end

    test "nil without metadata" do
      mock_llm(fn _body -> {:ok, %{answer: "yes"}} end)

      {:ok, _} = LLM.chat("hi", "trace_none_test", operation: "trace_none_test")

      assert last_log("trace_none_test").question_log_id == nil
    end
  end

  describe "call detail capture" do
    test "mock path records the user-message input preview" do
      mock_llm(fn _body -> {:ok, %{answer: "yes"}} end)

      {:ok, _} =
        LLM.chat("Can I move diagonally?", "trace_detail_test", operation: "trace_detail_test")

      detail = last_log("trace_detail_test").detail
      assert detail["input"] == "Can I move diagonally?"
    end

    test "long inputs are truncated" do
      mock_llm(fn _body -> {:ok, %{answer: "yes"}} end)
      long = String.duplicate("a", 5_000)

      {:ok, _} = LLM.chat(long, "trace_trunc_test", operation: "trace_trunc_test")

      detail = last_log("trace_trunc_test").detail
      assert String.ends_with?(detail["input"], "…[truncated]")
      assert String.length(detail["input"]) < 2_000
    end

    test "calls_for_question returns detail, defaulting to empty map for old rows" do
      Repo.insert!(%Log{
        provider: "openrouter",
        model: "google/gemini-2.5-flash",
        operation: "normalize",
        question_log_id: 4711,
        success: true,
        detail: %{"input" => "raw q", "output" => "clean q", "finish_reason" => "stop"}
      })

      Repo.insert!(%Log{
        provider: "openrouter",
        model: "google/gemini-2.5-flash",
        operation: "ask",
        question_log_id: 4711,
        success: true
      })

      %{calls: [normalize, ask]} = LLM.calls_for_question(4711)
      assert normalize.detail["input"] == "raw q"
      assert normalize.detail["output"] == "clean q"
      assert ask.detail == %{}
    end
  end

  describe "calls_for_question/1" do
    test "returns chronological calls with costs and totals" do
      base = %{
        provider: "openrouter",
        model: "google/gemini-2.5-flash",
        question_log_id: 99,
        success: true
      }

      Repo.insert!(
        struct(Log, Map.merge(base, %{
          operation: "ask",
          prompt_tokens: 1000,
          completion_tokens: 500,
          total_tokens: 1500,
          duration_ms: 2000
        }))
      )

      Repo.insert!(
        struct(Log, Map.merge(base, %{
          operation: "grounding_critic",
          prompt_tokens: 200,
          completion_tokens: 50,
          total_tokens: 250,
          duration_ms: 800,
          success: false,
          error_message: "boom"
        }))
      )

      # Unrelated row must not appear.
      Repo.insert!(struct(Log, Map.merge(base, %{operation: "ask", question_log_id: 100})))

      %{calls: calls, totals: totals} = LLM.calls_for_question(99)

      assert [%{operation: "ask"} = ask, %{operation: "grounding_critic"} = critic] = calls
      assert ask.cost == Pricing.cost("google/gemini-2.5-flash", 1000, 500)
      refute critic.success
      assert critic.error_message == "boom"

      assert totals.count == 2
      assert totals.duration_ms == 2800
      assert totals.tokens == 1750
      assert_in_delta totals.cost, ask.cost + critic.cost, 1.0e-12
    end

    test "empty trace for unknown question" do
      assert %{calls: [], totals: %{count: 0, cost: cost}} = LLM.calls_for_question(-1)
      assert cost == 0
    end
  end

  describe "AskWorker tagging" do
    test "a fresh ask tags its llm_logs rows with the question_log_id" do
      mock_llm(fn _body ->
        {:ok, %{answer: "Roll 3 dice.", cited_passage: "p.1", followup: false, followups: []}}
      end)

      Application.put_env(:rule_maven, :embed_mock, fn _ ->
        {:ok, List.duplicate(0.1, 768)}
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

      {:ok, game} = Games.create_game(%{name: "TraceGame #{System.unique_integer([:positive])}"})

      {:ok, ql} =
        Games.log_question(%{
          game_id: game.id,
          question: "How many dice?",
          answer: "Thinking...",
          user_id: nil
        })

      :ok =
        AskWorker.perform(%Oban.Job{
          id: System.unique_integer([:positive]),
          args: %{
            "game_id" => game.id,
            "question_log_id" => ql.id,
            "question" => "How many dice?"
          }
        })

      ops =
        Repo.all(
          from l in Log, where: l.question_log_id == ^ql.id, select: l.operation, order_by: l.id
        )

      assert "ask" in ops
    end
  end
end
