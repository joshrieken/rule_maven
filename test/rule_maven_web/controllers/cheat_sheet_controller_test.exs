defmodule RuleMavenWeb.CheatSheetControllerTest do
  @moduledoc """
  Covers the version-scoping fix: `show_version/2` must only ever serve a
  cheatsheet version that actually belongs to the game named by the URL
  token. Before the fix, `CheatSheet.get_version/1` did a bare `Repo.get/2` on
  the version id with no game check, so a logged-in user could swap in any
  other game's version id (via the token URL for game A + a version id
  belonging to game B) and read cross-game content.
  """

  use RuleMavenWeb.ConnCase, async: true
  import RuleMaven.GamesFixtures

  alias RuleMaven.{CheatSheet, Hashid}

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user!(prefix) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "#{prefix}_user",
        email: "#{prefix}_user@test.com",
        password: "password1234"
      })

    user
  end

  setup %{conn: conn} do
    user = create_user!("cheat_ctrl")

    game_a = published_game_fixture(%{name: "Game A", bgg_id: 90_001})
    game_b = published_game_fixture(%{name: "Game B", bgg_id: 90_002})

    [doc_b] = RuleMaven.Games.list_documents(game_b)
    {:ok, version_b} = CheatSheet.save_version(doc_b.id, "# Game B secrets", "compact")

    %{
      conn: login(conn, user),
      game_a: game_a,
      game_b: game_b,
      version_b: version_b
    }
  end

  test "version belonging to a different game 404s (cross-game IDOR)", %{
    conn: conn,
    game_a: game_a,
    version_b: version_b
  } do
    token_a = Hashid.encode(game_a.id)
    version_token_b = Hashid.encode(version_b.id)

    conn = get(conn, ~p"/games/#{token_a}/cheatsheet/#{version_token_b}")

    assert conn.status == 404
    refute conn.resp_body =~ "Game B secrets"
  end

  test "version belonging to the correct game is served", %{
    conn: conn,
    game_b: game_b,
    version_b: version_b
  } do
    token_b = Hashid.encode(game_b.id)
    version_token_b = Hashid.encode(version_b.id)

    conn = get(conn, ~p"/games/#{token_b}/cheatsheet/#{version_token_b}")

    assert conn.status == 200
    assert conn.resp_body =~ "Game B secrets"
  end
end
