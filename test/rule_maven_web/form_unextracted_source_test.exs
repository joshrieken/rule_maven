defmodule RuleMavenWeb.FormUnextractedSourceTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  # Regression: uploading was separated from processing, so a just-saved source
  # has full_text: nil until extraction runs later on the Prepare page. The manage
  # tab's cleanup buttons ran String.trim(entry.text) on that nil and crashed the
  # LiveView on render — the user saw "Lost connection" right after upload. We
  # drive the exact path: the download worker's {:download_done} message, which
  # switches to the manage tab and re-renders the freshly added source.
  test "manage tab re-renders after a source is saved but not yet extracted",
       %{conn: conn} do
    {:ok, admin} =
      RuleMaven.Users.create_user(%{
        username: "form_unextracted_admin",
        email: "fua@test.com",
        password: "password1234",
        role: "admin"
      })

    # min_players set so bgg_synced?/1 is true — the tabbed editor (and the
    # manage tab that holds the crashing cleanup buttons) only renders past the
    # BGG gate.
    game = game_fixture(%{name: "Unextracted Game", min_players: 2})
    pdf_path = "uploads/rulebooks/fresh.pdf"

    {:ok, _doc} =
      RuleMaven.Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        pdf_path: pdf_path,
        full_text: nil,
        pages: [%{index: 0, sheet: 1, printed: 1, text: nil, cleaned: nil}]
      })

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})
    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/edit")

    # Worker signals the download/save finished — this flips to the manage tab and
    # renders the source's editor + cleanup buttons. Must not crash on the nil text.
    send(view.pid, {:download_done, game.id, pdf_path})
    html = render(view)

    assert html =~ "Rulebook Sources"
  end
end
