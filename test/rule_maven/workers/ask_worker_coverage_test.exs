defmodule RuleMaven.Workers.AskWorkerCoverageTest do
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures

  alias RuleMaven.Coverage
  alias RuleMaven.Repo

  # This proves the wiring CONTRACT AskWorker relies on: `resolve_document_ids/2`
  # stamps a citation's `"document_id"` off its `"source"` label, that stamped
  # value is what the worker writes into the scalar `question_log.document_id`
  # column, and `record_citations/1` (called beside `maybe_award_mastery/2`)
  # turns the persisted citations into a coverage row. Driving the full worker
  # would require mocking `RuleMaven.LLM.ask/5`'s entire return shape; this
  # exercises the same three calls the worker makes, in the same order, against
  # a real published document.
  test "resolved citations stamp scalar document_id and record coverage" do
    game = game_fixture()

    {:ok, doc} =
      %RuleMaven.Games.Document{}
      |> RuleMaven.Games.Document.changeset(%{
        label: "Rulebook",
        game_id: game.id,
        page_count: 10,
        status: "published"
      })
      |> Repo.insert()

    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "coverage_user_#{System.unique_integer([:positive])}",
        email: "coverage_user_#{System.unique_integer([:positive])}@test.com",
        password: "supersecretpassword123"
      })

    {:ok, ql} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "Can I do that?",
        answer: "Thinking..."
      })

    # Mirrors AskWorker's citation-build step: raw citations reference the
    # document only by its "source" label, exactly as the LLM returns them.
    raw_citations = [%{"quote" => "text", "page" => 4, "source" => "Rulebook"}]

    stamped = Coverage.resolve_document_ids(raw_citations, [game.id])
    assert [%{"document_id" => resolved_doc_id}] = stamped
    assert resolved_doc_id == doc.id

    primary = List.first(stamped)

    # Mirrors the worker's update_attrs: citations carry the stamped
    # document_id, and the scalar column is set from the primary citation.
    {:ok, updated} =
      RuleMaven.Games.log_question_update(ql, %{
        answer: "Yes.",
        citations: stamped,
        citation_valid: true,
        document_id: primary["document_id"]
      })

    assert updated.document_id == doc.id
    assert [%{"document_id" => ^resolved_doc_id}] = updated.citations

    # Mirrors the worker's best-effort record_citations call beside
    # maybe_award_mastery/2.
    assert {:ok, 1} = Coverage.record_citations(updated)
    assert Coverage.for_document(doc.id).covered == 1

    # Idempotent — a duplicate-execution re-run inserts nothing new.
    assert {:ok, 0} = Coverage.record_citations(updated)
    assert Coverage.for_document(doc.id).covered == 1
  end

  test "unresolved source label leaves document_id nil and records no coverage" do
    game = game_fixture()

    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "coverage_user_#{System.unique_integer([:positive])}",
        email: "coverage_user_#{System.unique_integer([:positive])}@test.com",
        password: "supersecretpassword123"
      })

    {:ok, ql} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "Can I do that?",
        answer: "Thinking..."
      })

    raw_citations = [%{"quote" => "text", "page" => 4, "source" => "Unpublished Appendix"}]
    stamped = Coverage.resolve_document_ids(raw_citations, [game.id])
    primary = List.first(stamped) || %{"quote" => nil, "page" => nil, "source" => nil}

    {:ok, updated} =
      RuleMaven.Games.log_question_update(ql, %{
        answer: "Yes.",
        citations: stamped,
        citation_valid: true,
        document_id: primary["document_id"]
      })

    assert is_nil(updated.document_id)
    assert {:ok, 0} = Coverage.record_citations(updated)
  end
end
