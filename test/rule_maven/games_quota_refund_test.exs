defmodule RuleMaven.GamesQuotaRefundTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.QuestionLog

  defp user(name) do
    Repo.insert!(%RuleMaven.Users.User{
      username: name,
      email: "#{name}@test.com",
      password_hash: "x"
    })
  end

  defp ask_call(user, game, question_log_id) do
    Repo.insert!(%RuleMaven.LLM.Log{
      provider: "openrouter",
      model: "google/gemini-2.5-flash",
      operation: "ask",
      success: true,
      user_id: user.id,
      game_id: game.id,
      question_log_id: question_log_id
    })
  end

  defp since, do: DateTime.add(DateTime.utc_now(), -1, :day)

  test "deleting the question row does not refund the ask" do
    {:ok, game} = Games.create_game(%{name: "QuotaGame"})
    u = user("quota_u")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "how many dice",
        answer: "Three.",
        visibility: "private"
      })

    ask_call(u, game, ql.id)
    assert Games.recent_question_count(u.id, since()) == 1

    # Regenerate/thread-delete removes the row. The paid call still happened,
    # so the quota counter must not roll back — otherwise ask→delete→ask is an
    # unlimited free-answer loop.
    Games.delete_question(ql)
    assert Games.recent_question_count(u.id, since()) == 1
  end

  test "retries within one ask count once" do
    {:ok, game} = Games.create_game(%{name: "QuotaRetryGame"})
    u = user("quota_retry_u")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "q",
        answer: "a",
        visibility: "private"
      })

    # Escalation + ungrounded retry both re-issue the "ask" operation.
    ask_call(u, game, ql.id)
    ask_call(u, game, ql.id)
    ask_call(u, game, ql.id)

    assert Games.recent_question_count(u.id, since()) == 1
  end

  test "a pool hit costs no quota" do
    {:ok, game} = Games.create_game(%{name: "QuotaPoolGame"})
    u = user("quota_pool_u")

    # A pool hit never issues an "ask" call, so it logs nothing.
    {:ok, _ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "q",
        answer: "a",
        visibility: "private"
      })

    assert Games.recent_question_count(u.id, since()) == 0
  end

  test "a surviving failed answer stays exempt" do
    {:ok, game} = Games.create_game(%{name: "QuotaErrGame"})
    u = user("quota_err_u")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "q",
        answer: "⚠️ Something went wrong. Please retry.",
        visibility: "private"
      })

    Repo.update_all(from(q in QuestionLog, where: q.id == ^ql.id), set: [error_kind: "unknown"])
    ask_call(u, game, ql.id)

    assert Games.recent_question_count(u.id, since()) == 0
  end
end
