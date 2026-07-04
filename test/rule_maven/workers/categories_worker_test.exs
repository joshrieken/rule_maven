defmodule RuleMaven.Workers.CategoriesWorkerTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Workers.CategoriesWorker

  defp game_with_text! do
    {:ok, game} = Games.create_game(%{name: "Cat Test Game"})

    {:ok, _doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        full_text: "Combat happens when heroes meet monsters. Movement uses spaces."
      })

    game
  end

  defp last_run! do
    Repo.one!(
      from r in "job_runs",
        where: r.kind == "categories",
        order_by: [desc: r.id],
        limit: 1,
        select: %{state: r.state, summary: r.summary}
    )
  end

  test "marks the run failed when the model yields no categories" do
    game = game_with_text!()

    # Empty content parses to zero categories; a "done — 0 categories" run
    # reads as success in the job log while the step stays pending forever.
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok, %{answer: "", finish_reason: "stop"}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert :ok = CategoriesWorker.perform(%Oban.Job{id: nil, args: %{"game_id" => game.id}})

    run = last_run!()
    assert run.state == "failed"
    assert Games.list_game_categories(game) == []
  end

  test "saves categories and finishes done on a real result" do
    game = game_with_text!()

    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok, %{answer: "Combat: fighting\nMovement: moving around", finish_reason: "stop"}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert :ok = CategoriesWorker.perform(%Oban.Job{id: nil, args: %{"game_id" => game.id}})

    run = last_run!()
    assert run.state == "done"
    assert length(Games.list_game_categories(game)) == 2
  end
end
