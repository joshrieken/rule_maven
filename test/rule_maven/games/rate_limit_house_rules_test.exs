defmodule RuleMaven.Games.RateLimitHouseRulesTest do
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Users

  defp user_fixture do
    {:ok, u} =
      Users.create_user(%{
        username: "hrq_user_#{System.unique_integer([:positive])}",
        email: "hrq_user_#{System.unique_integer([:positive])}@test.com",
        password: "testpass1234"
      })

    u
  end

  test "house_rule_check llm_logs rows count against the monthly quota" do
    user = user_fixture()
    {:ok, user} = Users.set_quota(user, 2)

    for _ <- 1..2 do
      RuleMaven.Repo.insert!(%RuleMaven.LLM.Log{
        operation: "house_rule_check",
        user_id: user.id,
        model: "test",
        provider: "test",
        success: true
      })
    end

    assert {:error, msg} = Games.check_rate_limit(user)
    assert msg =~ "Monthly"
  end

  test "other llm_logs operations do not count against the quota" do
    user = user_fixture()
    {:ok, user} = Users.set_quota(user, 2)

    for _ <- 1..5 do
      RuleMaven.Repo.insert!(%RuleMaven.LLM.Log{
        operation: "chat_cleanup",
        user_id: user.id,
        model: "test",
        provider: "test",
        success: true
      })
    end

    assert :ok = Games.check_rate_limit(user)
  end

  test "fresh ask rows and house_rule_check rows sum against the same quota" do
    user = user_fixture()
    {:ok, user} = Users.set_quota(user, 2)
    game = game_fixture()

    RuleMaven.Repo.insert!(%QuestionLog{
      game_id: game.id,
      user_id: user.id,
      question: "How many cards?",
      answer: "Six.",
      pool_source_id: nil
    })

    RuleMaven.Repo.insert!(%RuleMaven.LLM.Log{
      operation: "house_rule_check",
      user_id: user.id,
      model: "test",
      provider: "test",
      success: true
    })

    assert {:error, msg} = Games.check_rate_limit(user)
    assert msg =~ "Monthly"
  end
end
