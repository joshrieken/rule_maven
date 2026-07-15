defmodule RuleMaven.Workers.AskWorkerIdempotencyTest do
  @moduledoc """
  Oban is at-least-once: a job whose first run already persisted an answer can
  execute a second time (max_attempts: 2, plus orphan rescue after a node
  restart). The rerun must not pay for a second LLM call, overwrite the good
  answer, or broadcast a duplicate :ask_complete.

  Also covers the takedown gate: the LiveView blocks new asks on a taken-down
  game, but a job already in the queue would otherwise run to completion.
  """

  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Workers.AskWorker

  defp user(name) do
    Repo.insert!(%RuleMaven.Users.User{
      username: name,
      email: "#{name}@test.com",
      password_hash: "x"
    })
  end

  # No llm_mock is configured anywhere in this file: if AskWorker fell through
  # to LLM.ask it would hit the real HTTP client rather than returning :ok.
  defp perform(args),
    do: AskWorker.perform(%Oban.Job{id: System.unique_integer([:positive]), args: args})

  defp args(game, ql, u),
    do: %{
      "game_id" => game.id,
      "question_log_id" => ql.id,
      "question" => ql.question,
      "user_id" => u.id
    }

  test "a rerun over an already-answered row skips the LLM and preserves the answer" do
    {:ok, game} = Games.create_game(%{name: "IdemGame"})
    u = user("idem_u")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How many dice do I roll?",
        answer: "Roll 3 dice.",
        promoted: false
      })

    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    assert :ok = perform(args(game, ql, u))

    # Answer untouched. The duplicate execution DOES re-broadcast completion:
    # the first run may have crashed after persisting but before its own
    # broadcast, leaving the asker's LiveView on "Thinking..." forever. The
    # handler re-reads the row, so the repeat is harmless.
    assert Repo.get!(QuestionLog, ql.id).answer == "Roll 3 dice."
    assert_receive {:ask_complete, %{question_log_id: qid}}, 100
    assert qid == ql.id
    refute_receive {:ask_error, _}, 100
  end

  test "a stuck Thinking... row is still re-driven (retry must not be blocked)" do
    {:ok, game} = Games.create_game(%{name: "IdemThinkingGame"})
    u = user("idem_thinking_u")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How many dice?",
        answer: "Thinking...",
        promoted: false
      })

    # The guard must NOT short-circuit here — it falls through to the real
    # pipeline, which without an llm_mock fails and writes a ⚠️ error answer.
    # Either way it must not remain the untouched sentinel.
    perform(args(game, ql, u))

    refute Repo.get!(QuestionLog, ql.id).answer == "Thinking..."
  end

  test "a queued job for a taken-down game does not spend" do
    {:ok, game} = Games.create_game(%{name: "TakedownGame"})
    u = user("takedown_u")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How many dice do I roll?",
        answer: "Thinking...",
        promoted: false
      })

    {:ok, game} = Games.take_down_game(game, "DMCA", "rightsholder")
    assert Games.taken_down?(game)

    assert :ok = perform(args(game, ql, u))

    answer = Repo.get!(QuestionLog, ql.id).answer
    assert answer =~ "unavailable"
    refute answer == "Thinking..."
  end
end
