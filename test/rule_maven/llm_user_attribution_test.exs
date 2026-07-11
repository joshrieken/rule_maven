defmodule RuleMaven.LLMUserAttributionTest do
  @moduledoc """
  Regression coverage for the per-user LLM cost cap: `llm_logs.user_id` must be
  populated for user-driven spend (ask, normalize, restyle), or
  `user_cost_today/1` (and the `user_daily_cost_cap` rate-limit branch) can
  never fire. `mock_llm/1` here also drives the mock through `log_llm/6` (same
  as production requests), so these assertions exercise the real logging path.
  """

  use RuleMaven.DataCase

  alias RuleMaven.{Games, LLM, Repo, Voices}
  alias RuleMaven.LLM.Log

  defp user(name) do
    Repo.insert!(%RuleMaven.Users.User{
      username: name,
      email: "#{name}@test.com",
      password_hash: "x"
    })
  end

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

  describe "ask/5 attribution" do
    test "a fresh (non-cached) answer logs the asker's user_id on the \"ask\" row" do
      mock_llm(fn _body ->
        {:ok, %{answer: "You roll 3 dice.", cited_passage: "p.1", followup: false, followups: []}}
      end)

      {:ok, game} = Games.create_game(%{name: "AttribAskGame"})
      u = user("attrib_asker")

      {:ok, _result} = LLM.ask(game, "How many dice do I roll?", [], [], user_id: u.id)

      log = last_log("ask")
      assert log.user_id == u.id
    end
  end

  describe "normalize_question/4 attribution" do
    test "the cheap cleanup call logs the asker's user_id on the \"normalize\" row" do
      mock_llm(fn _body -> {:ok, %{answer: "How many dice?"}} end)

      {:ok, game} = Games.create_game(%{name: "AttribNormalizeGame"})
      u = user("attrib_normalizer")

      # Followup context forces the non-cached do_normalize/4 branch.
      LLM.normalize_question(game, "what about on a road?", [{"q", "a"}], user_id: u.id)

      log = last_log("normalize")
      assert log.user_id == u.id
    end
  end

  describe "Voices.restyle/5 attribution" do
    test "a fresh restyle logs the requesting user's user_id on the \"voice\" row" do
      mock_llm(fn _body ->
        {:ok, %{answer: "A pirate's take on the rule.", finish_reason: "stop"}}
      end)

      {:ok, game} = Games.create_game(%{name: "AttribVoiceGame"})
      u = user("attrib_restyler")

      {:ok, ql} =
        Games.log_question(%{
          game_id: game.id,
          user_id: u.id,
          question: "How many dice?",
          answer: "You roll 3 dice.",
          visibility: "private"
        })

      {:ok, _content} = Voices.restyle(ql.id, "pirate", ql.answer, game, user_id: u.id)

      log = last_log("voice")
      assert log.user_id == u.id
    end
  end
end
