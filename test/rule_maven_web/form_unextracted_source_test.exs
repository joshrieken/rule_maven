defmodule RuleMavenWeb.FormUnextractedSourceTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  defp admin!(name) do
    {:ok, admin} =
      RuleMaven.Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "password1234",
        role: "admin"
      })

    admin
  end

  # min_players set so bgg_synced?/1 is true — the tabbed editor (and the manage
  # tab that holds the crashing cleanup buttons) only renders past the BGG gate.
  defp unextracted_game do
    game = game_fixture(%{name: "Unextracted Game", min_players: 2})

    {:ok, _doc} =
      RuleMaven.Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        pdf_path: "uploads/rulebooks/x.pdf",
        full_text: nil,
        # A source split into pages but not yet extracted: page text is nil, and
        # so is the document's derived full_text (which the entry's :text mirrors).
        pages: [%{index: 0, sheet: 1, printed: 1, text: nil, cleaned: nil}]
      })

    game
  end

  # Regression: uploading was separated from processing, so a just-saved source
  # has full_text: nil until extraction runs later on the Prepare page. The manage
  # tab's cleanup buttons ran String.trim(entry.text) on that nil and crashed the
  # LiveView on render — the user saw "Lost connection".
  test "manage tab renders a source that hasn't been extracted yet", %{conn: conn} do
    admin = admin!("form_unextracted_admin")
    game = unextracted_game()

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})

    {:ok, _view, html} =
      live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/edit?tab=manage")

    assert html =~ "Rulebook Sources"
  end

  # A URL download finishes asynchronously; its {:download_done} broadcast sends
  # the admin to the prepare page.
  test "URL-download completion redirects to the prepare page", %{conn: conn} do
    admin = admin!("form_redirect_admin")
    game = unextracted_game()
    token = RuleMaven.Hashid.encode(game.id)

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})
    {:ok, view, _html} = live(conn, "/games/#{token}/edit")

    send(view.pid, {:download_done, game.id, "uploads/rulebooks/x.pdf"})

    assert_redirect(view, "/games/#{token}/prepare")
  end

  # A local PDF upload is ingested synchronously (extraction is deferred), so the
  # source row exists before we navigate — the prepare page never renders an empty
  # pipeline.
  test "uploading a PDF ingests the source synchronously, then redirects to prepare",
       %{conn: conn} do
    admin = admin!("form_upload_admin")
    # min_players → bgg_synced, so the editor (and its upload UI) renders.
    game = game_fixture(%{name: "Upload Target", min_players: 2})
    token = RuleMaven.Hashid.encode(game.id)

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})
    {:ok, view, _html} = live(conn, "/games/#{token}/edit")

    file =
      file_input(view, "#game-form", :rulebook_pdfs, [
        %{name: "Rules.pdf", content: "%PDF-1.4 dummy", type: "application/pdf"}
      ])

    render_upload(file, "Rules.pdf")
    render_click(view, "process_uploads")

    # Source is saved before navigation (synchronous ingest, no worker race).
    assert length(RuleMaven.Games.list_documents(game)) == 1
    assert_redirect(view, "/games/#{token}/prepare")
  end
end
