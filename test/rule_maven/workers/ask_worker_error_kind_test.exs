defmodule RuleMaven.Workers.AskWorkerErrorKindTest do
  @moduledoc """
  Failed asks must persist a machine-readable `error_kind` alongside the
  human-facing "⚠️ ..." answer so the LiveView can offer the right affordance
  (bounded retry / cooldown / nothing), and must auto-file a moderation flag
  once the question's retries are exhausted.
  """

  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo, Settings}
  alias RuleMaven.Games.{QuestionFlag, QuestionLog}
  alias RuleMaven.Workers.AskWorker

  defp user(name) do
    Repo.insert!(%RuleMaven.Users.User{
      username: name,
      email: "#{name}@test.com",
      password_hash: "x"
    })
  end

  defp perform(args),
    do: AskWorker.perform(%Oban.Job{id: System.unique_integer([:positive]), args: args})

  defp provisional!(game, u, attrs \\ %{}) do
    {:ok, prov} =
      Games.log_question(
        Map.merge(
          %{
            game_id: game.id,
            user_id: u.id,
            question: "How many dice do I roll?",
            answer: "Thinking...",
            visibility: "private"
          },
          attrs
        )
      )

    prov
  end

  test "kill switch persists a ⚠️-prefixed answer with error_kind \"paused\"" do
    {:ok, _} = Settings.set_asks_disabled(true)
    {:ok, game} = Games.create_game(%{name: "PausedKindGame"})
    u = user("paused_kind_u")
    prov = provisional!(game, u)

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => prov.id,
               "question" => "How many dice do I roll?",
               "user_id" => u.id
             })

    updated = Repo.get(QuestionLog, prov.id)
    assert String.starts_with?(updated.answer, "⚠️")
    assert updated.error_kind == "paused"
    # Paused is not the user's failure and never auto-reports.
    assert Repo.aggregate(QuestionFlag, :count) == 0
  end

  test "LLM failure is classified and auto-flags once retries are exhausted" do
    {:ok, game} = Games.create_game(%{name: "ErrorKindGame"})
    u = user("error_kind_u")

    # No chunks + no mocks: LLM.ask errors out, exercising the {:error, _}
    # terminal branch. The provisional row already carries the final allowed
    # retry, so this failure must trip the auto-report.
    prov = provisional!(game, u, %{error_retries: Games.error_retry_limit()})

    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => prov.id,
               "question" => "How many dice do I roll?",
               "user_id" => u.id
             })

    assert_received {:ask_error, %{question_log_id: qid}}
    assert qid == prov.id

    updated = Repo.get(QuestionLog, prov.id)
    assert String.starts_with?(updated.answer, "⚠️")
    assert updated.error_kind != nil

    flag = Repo.one(QuestionFlag)
    assert flag.question_log_id == prov.id
    assert flag.user_id == u.id
    assert flag.reason =~ "auto: answer failed repeatedly"
  end

  test "LLM failure with retries remaining does not auto-flag" do
    {:ok, game} = Games.create_game(%{name: "ErrorKindNoFlagGame"})
    u = user("error_kind_noflag_u")
    prov = provisional!(game, u)

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => prov.id,
               "question" => "How many dice do I roll?",
               "user_id" => u.id
             })

    updated = Repo.get(QuestionLog, prov.id)
    assert updated.error_kind != nil
    assert Repo.aggregate(QuestionFlag, :count) == 0
  end
end
