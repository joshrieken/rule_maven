defmodule RuleMavenWeb.GameFormUnextractedRenameTest do
  @moduledoc """
  Regression test for a bug where renaming a rulebook on the edit page (Save)
  would silently delete any document that hadn't finished extraction yet
  (empty `pages`, blank `full_text` — the state right after upload, before
  the Prepare page runs extraction). The save handler's source_map filter
  required non-blank page text before keeping an entry, so unextracted
  documents were dropped from source_map and then hard-deleted by
  save_game/4's "prune anything not in source_map" logic.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp admin_user(name) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "password1234",
        role: "admin"
      })

    user
  end

  test "renaming an unextracted document on save does not delete it", %{conn: conn} do
    user = admin_user("unextracted_rename_user")
    game = game_fixture(%{name: "Unextracted Game", image_url: "http://example.com/box.jpg"})

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Old Name",
        full_text: nil,
        pages: [],
        kind: "rulebook"
      })

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/edit")

    view
    |> form("#game-form", %{
      "game" => %{"name" => game.name},
      "label_0" => "New Name"
    })
    |> render_submit()

    assert Games.get_document!(doc.id).label == "New Name"
  end
end
