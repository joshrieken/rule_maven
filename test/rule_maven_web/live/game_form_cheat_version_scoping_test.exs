defmodule RuleMavenWeb.GameFormCheatVersionScopingTest do
  @moduledoc """
  Critical security review finding: form.ex's `delete_version` and
  `set_active_version` handlers used to look up the cheatsheet version by a
  raw, globally-unscoped id (`CheatSheet.get_version!/1`). An admin viewing
  Game A's edit page could fire either event with a version id copied from
  Game B's cheatsheet and delete/activate it — cross-game write via an
  event the UI never legitimately renders.

  Fixed by routing through `CheatSheet.get_version_for_game/2`, which scopes
  the lookup to the document's game and returns nil on any mismatch.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.{CheatSheet, Games, Repo}
  alias RuleMaven.CheatSheet.CheatSheetVersion

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

  defp document_fixture(game) do
    {:ok, doc} =
      %Games.Document{}
      |> Games.Document.changeset(%{
        label: "Rulebook",
        full_text: "Test rulebook text.",
        game_id: game.id,
        status: "published"
      })
      |> Repo.insert()

    doc
  end

  defp version_fixture(document_id, content) do
    {:ok, version} = CheatSheet.save_version(document_id, content)
    version
  end

  setup do
    game_a =
      game_fixture(%{name: "Game A", image_url: "http://example.com/a.jpg", bgg_id: 100_001})

    game_b =
      game_fixture(%{name: "Game B", image_url: "http://example.com/b.jpg", bgg_id: 100_002})

    doc_a = document_fixture(game_a)
    doc_b = document_fixture(game_b)

    version_a = version_fixture(doc_a.id, "Game A cheat sheet")
    version_b = version_fixture(doc_b.id, "Game B cheat sheet")

    %{game_a: game_a, game_b: game_b, doc_b: doc_b, version_a: version_a, version_b: version_b}
  end

  test "delete_version cannot delete another game's version", %{
    conn: conn,
    game_a: game_a,
    version_b: version_b
  } do
    user = admin_user("cross_delete_admin")
    conn = login(conn, user)

    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game_a.id)}/edit")

    html =
      render_click(view, "delete_version", %{"id" => to_string(version_b.id)})

    assert html =~ "Version not found."
    assert Repo.get(CheatSheetVersion, version_b.id), "other game's version must survive"
  end

  test "set_active_version cannot activate another game's version", %{
    conn: conn,
    game_a: game_a,
    doc_b: doc_b,
    version_b: version_b
  } do
    # version_b is already active (first version for its document defaults to
    # active). Add a second, inactive version for the same game_b document,
    # then confirm an admin on game_a's page can't flip it active.
    inactive_version_b = version_fixture(doc_b.id, "Game B second cheat sheet")
    refute inactive_version_b.active

    user = admin_user("cross_activate_admin")
    conn = login(conn, user)

    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game_a.id)}/edit")

    html =
      render_click(view, "set_active_version", %{"id" => to_string(inactive_version_b.id)})

    assert html =~ "Version not found."

    refute Repo.get(CheatSheetVersion, inactive_version_b.id).active,
           "other game's version must not become active"

    assert Repo.get(CheatSheetVersion, version_b.id).active,
           "other game's original active version must remain untouched"
  end

  test "delete_version still deletes a version belonging to the current game", %{
    conn: conn,
    game_a: game_a,
    version_a: version_a
  } do
    user = admin_user("same_game_delete_admin")
    conn = login(conn, user)

    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game_a.id)}/edit")

    html = render_click(view, "delete_version", %{"id" => to_string(version_a.id)})

    assert html =~ "Version deleted."
    refute Repo.get(CheatSheetVersion, version_a.id)
  end
end
