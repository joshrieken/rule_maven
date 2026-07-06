defmodule RuleMaven.Workers.HouseRuleCheckWorkerTest do
  use RuleMaven.DataCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  alias RuleMaven.{Games, HouseRules, Repo, Users}
  alias RuleMaven.Games.Chunk
  alias RuleMaven.Workers.HouseRuleCheckWorker

  defp user_fixture do
    {:ok, u} =
      Users.create_user(%{
        username: "hr_user_#{System.unique_integer([:positive])}",
        email: "hr_user_#{System.unique_integer([:positive])}@test.com",
        password: "testpass1234"
      })

    u
  end

  defp stub_llm_success do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer:
           ~s({"verdict":"overrides","raw_quote":"Deal 5 cards.","note":"Changes hand size.","citations":[]}),
         finish_reason: "stop"
       }}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp stub_llm_error do
    Application.put_env(:rule_maven, :llm_mock, fn _body -> {:error, :boom} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  setup do
    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

    user = user_fixture()

    {:ok, game} =
      Games.create_game(%{name: "HouseRuleGame #{System.unique_integer([:positive])}"})

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Core rules",
        kind: "rulebook",
        full_text: "seed"
      })

    {:ok, doc} = Games.update_document(doc, %{status: "published"})

    Repo.insert!(%Chunk{
      document_id: doc.id,
      chunk_index: 0,
      content: "[Page 5]\nPlayers are dealt 6 cards to start.",
      page_number: 5,
      embedding: Pgvector.new(List.duplicate(0.1, 768))
    })

    {:ok, hr} = HouseRules.create(user, game.id, %{"body" => "We deal 5 cards."})

    %{user: user, game: game, hr: hr}
  end

  test "success path persists verdict and broadcasts", %{game: game, hr: hr} do
    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")
    stub_llm_success()

    assert :ok =
             perform_job(HouseRuleCheckWorker, %{
               "house_rule_id" => hr.id,
               "game_id" => game.id
             })

    hr = HouseRules.get(hr.id)
    assert hr.check_status == "done"
    assert hr.verdict == "overrides"
    id = hr.id
    assert_received {:house_rule_checked, ^id}
  end

  test "LLM failure marks failed and still broadcasts", %{game: game, hr: hr} do
    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")
    stub_llm_error()

    perform_job(
      HouseRuleCheckWorker,
      %{"house_rule_id" => hr.id, "game_id" => game.id},
      attempt: 3
    )

    assert HouseRules.get(hr.id).check_status == "failed"
    assert_received {:house_rule_checked, _}
  end

  test "non-final-attempt LLM failure retries without marking failed", %{game: game, hr: hr} do
    stub_llm_error()

    assert {:error, :boom} =
             perform_job(
               HouseRuleCheckWorker,
               %{"house_rule_id" => hr.id, "game_id" => game.id},
               attempt: 1
             )

    assert HouseRules.get(hr.id).check_status == "pending"
  end

  test "deleted rule is a no-op", %{game: game, hr: hr} do
    {:ok, _} = HouseRules.delete(hr)

    assert :ok =
             perform_job(HouseRuleCheckWorker, %{
               "house_rule_id" => hr.id,
               "game_id" => game.id
             })
  end
end
