defmodule RuleMaven.Workers.SuggestionsWorkerTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo, Settings}
  alias RuleMaven.Workers.SuggestionsWorker

  defp game_with_text! do
    {:ok, game} = Games.create_game(%{name: "Suggest Test Game"})

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
        where: r.kind == "suggestions",
        order_by: [desc: r.id],
        limit: 1,
        select: %{state: r.state, summary: r.summary}
    )
  end

  test "marks the run failed and saves nothing when the model yields no suggestions" do
    game = game_with_text!()

    # An empty result must not persist "[]" — present?(suggestions_<id>) would
    # count the step done with zero suggestions to show.
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok, %{answer: "", finish_reason: "stop"}}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert :ok = SuggestionsWorker.perform(%Oban.Job{id: nil, args: %{"game_id" => game.id}})

    assert last_run!().state == "failed"
    assert Settings.get("suggestions_#{game.id}") == nil
  end

  test "saves suggestions and finishes done on a real result" do
    game = game_with_text!()

    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: "CATEGORY: Combat\n- How does combat work?\n- Who attacks first?",
         finish_reason: "stop"
       }}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert :ok = SuggestionsWorker.perform(%Oban.Job{id: nil, args: %{"game_id" => game.id}})

    assert last_run!().state == "done"
    assert [%{"category" => "Combat", "questions" => [_, _]}] =
             Jason.decode!(Settings.get("suggestions_#{game.id}"))
  end
end
