defmodule RuleMaven.Games.RateLimitHouseRulesTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.Games
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
end
