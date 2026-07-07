defmodule RuleMaven.Workers.HouseRuleDeltaWorkerTest do
  use RuleMaven.DataCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  alias RuleMaven.{Games, HouseRules, Users}
  alias RuleMaven.Workers.HouseRuleDeltaWorker

  defp user_fixture do
    unique = System.unique_integer([:positive])

    {:ok, u} =
      Users.create_user(%{
        username: "hrd_user_#{unique}",
        email: "hrd_user_#{unique}@test.com",
        password: "testpass1234"
      })

    u
  end

  defp setup_pair do
    user = user_fixture()
    {:ok, game} = Games.create_game(%{name: "DeltaGame #{System.unique_integer([:positive])}"})
    {:ok, hr} = HouseRules.create(user, game.id, %{"body" => "We deal 6 cards, not 5."})

    {:ok, hr} =
      HouseRules.mark_checked(hr, %{
        verdict: "overrides",
        raw_quote: "Deal 5 cards to each player.",
        check_note: "Changes hand size.",
        citations: []
      })

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        question: "How many cards do I draw?",
        answer: "You draw 5 cards."
      })

    {game, hr, ql}
  end

  defp stub_llm(text) do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok, %{answer: text, finish_reason: "stop"}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  test "caches the delta note and broadcasts done" do
    {game, hr, ql} = setup_pair()
    stub_llm("With your house rule, you draw 6 cards instead of 5.")
    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    assert :ok =
             perform_job(HouseRuleDeltaWorker, %{
               "house_rule_id" => hr.id,
               "question_log_id" => ql.id
             })

    assert HouseRules.get_delta(hr, ql).delta ==
             "With your house rule, you draw 6 cards instead of 5."

    hr_id = hr.id
    ql_id = ql.id
    assert_receive {:house_rule_delta, ^hr_id, ^ql_id, :done}
  end

  test "warm cache short-circuits without an LLM call" do
    {game, hr, ql} = setup_pair()
    {:ok, _} = HouseRules.save_delta(hr, ql, "already cached")

    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      flunk("LLM should not be called on a warm cache")
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    assert :ok =
             perform_job(HouseRuleDeltaWorker, %{
               "house_rule_id" => hr.id,
               "question_log_id" => ql.id
             })

    assert HouseRules.get_delta(hr, ql).delta == "already cached"

    hr_id = hr.id
    ql_id = ql.id
    assert_receive {:house_rule_delta, ^hr_id, ^ql_id, :done}
  end

  test "LLM failure on the last attempt broadcasts failed and caches nothing" do
    {game, hr, ql} = setup_pair()

    Application.put_env(:rule_maven, :llm_mock, fn _body -> {:error, :boom} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    assert :ok =
             perform_job(
               HouseRuleDeltaWorker,
               %{"house_rule_id" => hr.id, "question_log_id" => ql.id},
               attempt: 3,
               max_attempts: 3
             )

    assert HouseRules.get_delta(hr, ql) == nil

    hr_id = hr.id
    ql_id = ql.id
    assert_receive {:house_rule_delta, ^hr_id, ^ql_id, :failed}
  end

  test "deleted rule or question is a quiet no-op" do
    {_game, hr, ql} = setup_pair()

    assert :ok =
             perform_job(HouseRuleDeltaWorker, %{
               "house_rule_id" => hr.id + 999_999,
               "question_log_id" => ql.id
             })

    assert :ok =
             perform_job(HouseRuleDeltaWorker, %{
               "house_rule_id" => hr.id,
               "question_log_id" => ql.id + 999_999
             })
  end
end
