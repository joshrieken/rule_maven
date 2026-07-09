defmodule RuleMaven.Workers.CleanupWorkerBudgetTest do
  @moduledoc """
  A cleanup run gets a per-page LLM call allowance pooled across the run. When it
  runs out the policy is stop and mark for review — never silent truncation:
  pages cleaned before the overrun stay cleaned, the document is held at
  pending_review so half-cleaned text can't flow on to embedding, and the Jobs
  log says why.
  """
  use RuleMaven.DataCase
  use Oban.Testing, repo: RuleMaven.Repo

  alias RuleMaven.{Games, Jobs}
  alias RuleMaven.Workers.CleanupWorker

  setup do
    Application.put_env(:rule_maven, :llm_mock, fn body ->
      content = body.messages |> List.last() |> Map.fetch!(:content)
      {:ok, %{answer: String.upcase(content)}}
    end)

    on_exit(fn ->
      Application.delete_env(:rule_maven, :llm_mock)
      Application.delete_env(:rule_maven, :cleanup_llm_calls_per_page)
    end)

    :ok
  end

  defp doc_with_pages(full_text, status \\ "published") do
    {:ok, game} = Games.create_game(%{name: "Budget #{System.unique_integer([:positive])}"})

    {:ok, doc} =
      Games.create_document(%{game_id: game.id, label: "Rules", full_text: full_text})

    {:ok, doc} = Games.update_document(doc, %{status: status}, chunk: false)
    doc
  end

  defp perform(doc) do
    args = %{"document_id" => doc.id, "game_id" => doc.game_id}
    assert :ok = CleanupWorker.perform(%Oban.Job{args: args})
    Games.get_document!(doc.id)
  end

  defp last_run(doc) do
    Jobs.list_runs(limit: 50)
    |> Enum.find(&(&1.kind == "cleanup" and &1.scope_id == doc.id))
  end

  test "a run that fits its budget still finishes done and cleans every page" do
    doc = doc_with_pages("alpha rules here\fbeta rules here")

    updated = perform(doc)

    assert Enum.map(updated.pages, & &1.cleaned) == ["ALPHA RULES HERE", "BETA RULES HERE"]
    assert updated.status == "published", "a clean run must not demote the document"
    assert last_run(doc).state == "done"
  end

  test "an overrun keeps extracted pages, holds the doc for review, and fails the run" do
    # Zero calls per page: the very first clean call is refused.
    Application.put_env(:rule_maven, :cleanup_llm_calls_per_page, 0)

    doc = doc_with_pages("alpha rules here\fbeta rules here")
    updated = perform(doc)

    assert updated.status == "pending_review",
           "an over-budget cleanup must not leave the doc published"

    # Raw extraction survives untouched — no page was blanked.
    assert Enum.map(updated.pages, & &1.text) == ["alpha rules here", "beta rules here"]

    run = last_run(doc)
    assert run.state == "failed"
    assert run.summary =~ "over budget"
    assert run.summary =~ "Re-run Cleanup"

    events = Jobs.events(run.id, 100) |> Enum.map(& &1.message)
    assert Enum.any?(events, &(&1 =~ "LLM call budget"))
  end
end
