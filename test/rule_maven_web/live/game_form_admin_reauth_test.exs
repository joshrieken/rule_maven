defmodule RuleMavenWeb.GameFormAdminReauthTest do
  @moduledoc """
  Audit finding: `GameLive.Form` (`/games/new`, `/games/:id/edit`) used to sit
  in `live_session :default`, whose only admin gate was the mount/
  handle_params check — that check never re-ran on `handle_event`. An admin
  demoted mid-session kept a live socket that could still fire mutating
  events (e.g. `delete_game`) until reconnect.

  Fixed by moving both routes into `live_session :admin`, whose `reauth_event`
  hook (`RuleMavenWeb.UserLiveAuth.reauth_event/3`) re-checks admin standing
  from the DB before every event — the same mechanism already protecting
  Review/Prepare/the admin dashboards.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.{Repo, Users}

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp admin_user(name) do
    {:ok, user} =
      Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "password1234",
        role: "admin"
      })

    user
  end

  test "demoting an admin mid-session halts their next event on an open Form socket", %{
    conn: conn
  } do
    # A second admin so demote_admin/1 doesn't refuse as a last-admin lockout.
    _other_admin = admin_user("other_standing_admin")
    user = admin_user("demoted_form_admin")

    game = game_fixture(%{name: "Demote Test Game", image_url: "http://example.com/box.jpg"})

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/edit")

    # Demote after mount — the open socket still has the pre-demotion admin
    # user in its assigns.
    {:ok, _} = Users.demote_admin(user)

    result = render_click(view, "delete_game", %{})

    assert {:error, {:redirect, %{to: "/"}}} = result
    refute Process.alive?(view.pid)
    assert Repo.get(RuleMaven.Games.Game, game.id), "game must survive — event must not execute"
  end

  test "non-admin cannot mount the Form route at all", %{conn: conn} do
    {:ok, user} =
      Users.create_user(%{
        username: "not_an_admin",
        email: "not_an_admin@test.com",
        password: "password1234"
      })

    game = game_fixture(%{name: "Locked Game", image_url: "http://example.com/box.jpg"})

    conn = login(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/edit")
  end

  test "nil-game delete_version on /games/new flashes instead of crashing", %{conn: conn} do
    user = admin_user("new_game_admin")
    conn = login(conn, user)

    {:ok, view, _html} = live(conn, "/games/new")

    html = render_click(view, "delete_version", %{"id" => "1"})

    assert html =~ "Version not found."
    assert Process.alive?(view.pid)
  end

  test "nil-game set_active_version on /games/new flashes instead of crashing", %{conn: conn} do
    user = admin_user("new_game_admin2")
    conn = login(conn, user)

    {:ok, view, _html} = live(conn, "/games/new")

    html = render_click(view, "set_active_version", %{"id" => "1"})

    assert html =~ "Version not found."
    assert Process.alive?(view.pid)
  end
end
