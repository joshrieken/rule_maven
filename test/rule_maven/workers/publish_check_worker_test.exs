defmodule RuleMaven.Workers.PublishCheckWorkerTest do
  use RuleMaven.DataCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  alias RuleMaven.{Games, Repo, Users}
  alias RuleMaven.Workers.PublishCheckWorker

  import RuleMaven.GamesFixtures
  import RuleMaven.GroupsFixtures

  defp user_fixture do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Users.create_user(%{
        username: "pub_user_#{n}",
        email: "pub_user_#{n}@test.com",
        password: "testpass1234"
      })

    u
  end

  defp question_fixture(attrs) do
    game = game_fixture()
    owner = user_fixture()

    base = %{
      game_id: game.id,
      user_id: owner.id,
      question: "some question",
      answer: "some answer",
      browsable: true
    }

    {:ok, ql} =
      base
      |> Map.merge(Map.new(attrs))
      |> Games.log_question()

    ql
  end

  defp group_question_fixture(attrs) do
    owner = user_fixture()
    group = group_fixture(owner)

    attrs
    |> Map.new()
    |> Map.put_new(:group_id, group.id)
    |> then(&question_fixture(&1))
  end

  defp stub_llm(reply) do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok, %{answer: reply, finish_reason: "stop"}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp stub_llm_error do
    Application.put_env(:rule_maven, :llm_mock, fn _body -> {:error, :timeout} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  describe "perform/1" do
    test "a clean canonical question becomes browsable" do
      stub_llm("no")

      ql =
        group_question_fixture(
          canonical_question: "May a player retract a move?",
          browsable: false
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == true
    end

    test "a flagged question stays unbrowsable" do
      stub_llm("yes")

      ql =
        group_question_fixture(
          canonical_question: "Can Dave retract his move?",
          browsable: false
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == false
    end

    test "a missing canonical question stays unbrowsable and makes no LLM call" do
      Application.put_env(:rule_maven, :llm_mock, fn _body ->
        raise "LLM should not be called for a row with no canonical question"
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      ql = group_question_fixture(canonical_question: nil, browsable: false)

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == false
    end

    test "an LLM error fails closed" do
      stub_llm_error()

      ql =
        group_question_fixture(
          canonical_question: "May a player retract a move?",
          browsable: false
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == false
    end

    test "a garbage LLM reply fails closed" do
      stub_llm("Sure! I think no.")

      ql =
        group_question_fixture(
          canonical_question: "May a player retract a move?",
          browsable: false
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == false
    end

    test "a non-group row is never touched" do
      Application.put_env(:rule_maven, :llm_mock, fn _body ->
        raise "LLM should not be called for a non-group row"
      end)

      on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

      ql =
        question_fixture(
          group_id: nil,
          canonical_question: "May a player retract a move?",
          browsable: true
        )

      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => ql.id})
      assert Repo.reload!(ql).browsable == true
    end

    test "a nonexistent row is a no-op" do
      assert :ok = perform_job(PublishCheckWorker, %{"question_log_id" => -1})
    end
  end
end
