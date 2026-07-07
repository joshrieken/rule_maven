defmodule RuleMaven.GamesErrorRetryTest do
  @moduledoc """
  Failed-answer retry accounting: which error kinds are player-retryable,
  when retries-exhausted questions auto-file a moderation flag, and that
  failed asks don't burn the user's billable quota.
  """

  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.{QuestionFlag, QuestionLog}

  defp user(name) do
    Repo.insert!(%RuleMaven.Users.User{
      username: name,
      email: "#{name}@test.com",
      password_hash: "x"
    })
  end

  defp question!(game, user, attrs) do
    {:ok, q} =
      Games.log_question(
        Map.merge(
          %{
            game_id: game.id,
            user_id: user.id,
            question: "How many dice do I roll?",
            answer: "⚠️ Something went wrong. Please retry.",
            visibility: "private"
          },
          attrs
        )
      )

    q
  end

  describe "error_retryable?/1" do
    test "retryable kinds under the limit are retryable" do
      for kind <- ["empty", "format", "timeout", "unknown", "rate_limited"] do
        assert Games.error_retryable?(%QuestionLog{error_kind: kind, error_retries: 0})

        assert Games.error_retryable?(%QuestionLog{
                 error_kind: kind,
                 error_retries: Games.error_retry_limit() - 1
               })
      end
    end

    test "exhausted retries are not retryable" do
      refute Games.error_retryable?(%QuestionLog{
               error_kind: "timeout",
               error_retries: Games.error_retry_limit()
             })
    end

    test "non-retryable kinds and healthy rows are not retryable" do
      refute Games.error_retryable?(%QuestionLog{error_kind: "too_long", error_retries: 0})
      refute Games.error_retryable?(%QuestionLog{error_kind: "paused", error_retries: 0})

      refute Games.error_retryable?(%QuestionLog{
               error_kind: nil,
               error_retries: 0,
               answer: "Roll 3 dice."
             })

      refute Games.error_retryable?(nil)
    end

    test "legacy pre-error_kind failure rows (nil kind, ⚠️ answer) are retryable" do
      legacy = %QuestionLog{
        error_kind: nil,
        error_retries: 0,
        answer: "⚠️ The AI returned an unexpected response format. Please retry."
      }

      assert Games.error_retryable?(legacy)
      refute Games.error_retryable?(%{legacy | error_retries: Games.error_retry_limit()})
      # Refused/blocked ⚠️ rows (security filter) stay dead-ended.
      refute Games.error_retryable?(%{legacy | refused: true})
      refute Games.error_retryable?(%{legacy | blocked: true})
    end
  end

  describe "auto_flag_error/1" do
    test "files a moderation flag once retries are exhausted" do
      {:ok, game} = Games.create_game(%{name: "AutoFlagGame"})
      u = user("autoflag_u")

      q =
        question!(game, u, %{
          error_kind: "format",
          error_retries: Games.error_retry_limit()
        })

      assert {:ok, %QuestionFlag{} = flag} = Games.auto_flag_error(q)
      assert flag.question_log_id == q.id
      assert flag.user_id == u.id
      assert flag.reason =~ "auto: answer failed repeatedly (format)"
      refute flag.resolved
    end

    test "no-ops while retries remain, for paused, and for healthy rows" do
      {:ok, game} = Games.create_game(%{name: "AutoFlagNoopGame"})
      u = user("autoflag_noop_u")

      assert :noop =
               Games.auto_flag_error(
                 question!(game, u, %{error_kind: "timeout", error_retries: 0})
               )

      assert :noop =
               Games.auto_flag_error(
                 question!(game, u, %{
                   error_kind: "paused",
                   error_retries: Games.error_retry_limit()
                 })
               )

      assert :noop =
               Games.auto_flag_error(
                 question!(game, u, %{answer: "Roll 3 dice.", error_kind: nil, error_retries: 0})
               )

      assert Repo.aggregate(QuestionFlag, :count) == 0
    end
  end

  describe "recent_question_count/2 quota exclusion" do
    test "failed answers don't count as billable asks" do
      {:ok, game} = Games.create_game(%{name: "QuotaGame"})
      u = user("quota_u")
      since = DateTime.add(DateTime.utc_now(), -1, :hour)

      question!(game, u, %{answer: "Roll 3 dice.", error_kind: nil})
      question!(game, u, %{error_kind: "timeout"})
      question!(game, u, %{error_kind: "paused"})

      assert Games.recent_question_count(u.id, since) == 1
    end
  end
end
