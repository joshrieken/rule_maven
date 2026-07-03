defmodule RuleMavenWeb.FormPdfLinkTest do
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

  defp with_pdf_doc(game) do
    {:ok, doc} =
      RuleMaven.Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        pdf_path: "uploads/rulebooks/x.pdf",
        pages: []
      })

    doc
  end

  test "edit form shows View PDF link for sources with a stored PDF", %{conn: conn} do
    admin = admin!("form_pdf_admin")
    # min_players set so bgg_synced?/1 is true — the tabbed editor (and the manage
    # tab that holds source entries) only renders past the BGG gate.
    game = game_fixture(%{name: "Form PDF Game", bgg_id: 7790, min_players: 2})
    doc = with_pdf_doc(game)

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})
    {:ok, _view, html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/edit?tab=manage")

    assert html =~ "View PDF"
    assert html =~ "/rulebooks/#{RuleMaven.Hashid.encode(doc.id)}/pdf"
  end
end
