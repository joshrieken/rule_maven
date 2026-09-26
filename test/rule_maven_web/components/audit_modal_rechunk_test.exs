defmodule RuleMavenWeb.AuditModalRechunkTest do
  # Re-chunking a rulebook replaces its chunks (new ids), so an older answer's
  # recorded source_chunk_ids stop resolving. The Audit trail says when that
  # happened instead of showing an empty "Retrieved context".
  use RuleMavenWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.{Chunk, Document}
  alias RuleMaven.Repo
  alias RuleMavenWeb.AuditModal

  test "stale chunk ids render a re-chunked note, not an empty list" do
    {:ok, admin} =
      RuleMaven.Users.create_user(%{
        username: "audit_rechunk_#{System.unique_integer([:positive])}",
        email: "audit_rechunk_#{System.unique_integer([:positive])}@test.com",
        password: "password1234",
        role: "admin"
      })

    game = game_fixture(%{name: "Audit #{System.unique_integer([:positive])}"})

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{game_id: game.id, label: "Rules", full_text: "x", pages: []})
      |> Repo.insert()

    # The current chunk set (post re-chunk); the answer recorded an id that no
    # longer exists.
    Repo.insert!(%Chunk{document_id: doc.id, chunk_index: 0, content: "[Page 1]\nnew"})

    {:ok, q} =
      Games.log_question(%{game_id: game.id, user_id: admin.id, question: "q?", answer: "a."})

    Repo.update_all(
      from(x in RuleMaven.Games.QuestionLog, where: x.id == ^q.id),
      set: [source_chunk_ids: [-1, -2]]
    )

    audit = AuditModal.fetch(q.id, admin)
    assert audit.missing_chunks == 2
    assert audit.rechunked_at

    html = render_component(&AuditModal.audit_modal/1, audit: audit, current_user: admin)
    assert html =~ "Rulebook re-chunked on"
    assert html =~ "the 2 chunk(s) this answer was built from no longer exist"
    refute html =~ "No source chunks recorded"
  end
end
