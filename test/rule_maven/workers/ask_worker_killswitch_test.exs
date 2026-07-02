defmodule RuleMaven.Workers.AskWorkerKillSwitchTest do
  @moduledoc """
  A queued/retried ask job must re-check the admin kill switch at execution
  time (not just at enqueue time in the LiveView), so a job that was already
  sitting in the queue when an admin flips `asks_disabled` off doesn't spend.
  """

  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo, Settings}
  alias RuleMaven.Games.QuestionLog
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

  test "no-ops without calling the LLM when the kill switch is on" do
    {:ok, _} = Settings.set_asks_disabled(true)

    # No llm_mock configured: if AskWorker called through to LLM.ask it would
    # hit the real HTTP client and error/crash, not return :ok cleanly.
    {:ok, game} = Games.create_game(%{name: "KillSwitchGame"})
    u = user("killswitch_u")

    {:ok, prov} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How many dice do I roll?",
        answer: "Thinking...",
        visibility: "private"
      })

    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => prov.id,
               "question" => "How many dice do I roll?",
               "user_id" => u.id
             })

    assert_received {:ask_error, %{question_log_id: qid, error: message}}
    assert qid == prov.id
    assert message =~ "paused"

    updated = Repo.get(QuestionLog, prov.id)
    assert updated.answer =~ "paused"
    refute updated.answer == "Thinking..."
  end
end
