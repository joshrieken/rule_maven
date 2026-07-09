defmodule RuleMavenWeb.AdminViewGateTest do
  @moduledoc """
  The admin gate moved out of `live_session :admin` and into
  `UserLiveAuth.on_mount(:app, ...)`, which keys off the LiveView module. It must
  still halt a non-admin *before* mount — an in-mount redirect alone is
  client-side and does not stop a forged event on a raw socket.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp user(name, role) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "password1234",
        role: role
      })

    user
  end

  setup do
    {:ok, game: game_fixture(%{name: "Gate Game", bgg_id: System.unique_integer([:positive])})}
  end

  test "a plain user is redirected away from Prepare", %{conn: conn, game: game} do
    conn = login(conn, user("gate_plain", "user"))
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/games/#{game}/prepare")
  end

  test "a plain user is redirected away from the admin dashboard", %{conn: conn} do
    conn = login(conn, user("gate_plain2", "user"))
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/db")
  end

  test "a logged-out visitor is sent to login, not to /", %{conn: conn, game: game} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/games/#{game}/prepare")
  end

  test "an admin still mounts Prepare", %{conn: conn, game: game} do
    conn = login(conn, user("gate_admin", "admin"))
    assert {:ok, _view, _html} = live(conn, ~p"/games/#{game}/prepare")
  end

  test "an admin still mounts the games list", %{conn: conn} do
    conn = login(conn, user("gate_admin2", "admin"))
    assert {:ok, _view, _html} = live(conn, ~p"/")
  end
end
