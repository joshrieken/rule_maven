defmodule RuleMavenWeb.PasswordAuthTest do
  # Sign-on config is global (Application env): not async.
  use RuleMavenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RuleMaven.{FakeOidc, Users}

  setup do
    FakeOidc.configure(name: "Low-Cal Calzone Zone")

    {:ok, user} =
      Users.create_user(%{
        username: "pwuser",
        email: "pw@example.com",
        password: "correct horse 1"
      })

    %{user: user}
  end

  defp refused?(conn) do
    redirected_to(conn) == ~p"/login" and
      Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign in with Low-Cal Calzone Zone"
  end

  test "password login refuses, even with the right password", %{conn: conn} do
    conn =
      post(conn, ~p"/login", session: %{"username" => "pwuser", "password" => "correct horse 1"})

    assert refused?(conn)
    refute get_session(conn, :user_id)
  end

  test "password reset, sign-in links, confirmation and auto-login refuse", %{conn: conn} do
    for {method, path, params} <- [
          {:get, "/reset-password", %{}},
          {:post, "/reset-password", %{"reset" => %{"email" => "pw@example.com"}}},
          {:get, "/reset-password/tok", %{}},
          {:post, "/reset-password/tok",
           %{"reset" => %{"password" => "x", "password_confirmation" => "x"}}},
          {:get, "/magic-link", %{}},
          {:post, "/magic-link", %{"magic_link" => %{"email" => "pw@example.com"}}},
          {:get, "/magic-link/tok", %{}},
          {:get, "/confirm/tok", %{}},
          {:get, "/auto-login", %{"token" => "tok"}}
        ] do
      result = dispatch(conn, @endpoint, method, path, params)
      assert refused?(result), "#{method} #{path} was not refused"
      refute get_session(result, :user_id)
    end

    refute_received {:email, _}
  end

  test "registration refuses", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login", flash: flash}}} = live(conn, ~p"/register")
    assert flash["error"] =~ "Sign in with Low-Cal Calzone Zone"
  end

  test "the header no longer offers Register", %{conn: conn} do
    html = conn |> get(~p"/help") |> html_response(200)
    refute html =~ ~s(href="/register")
  end

  test "changing a password from Settings refuses", %{conn: conn, user: user} do
    {:ok, view, _html} =
      conn
      |> Plug.Test.init_test_session(%{
        "user_id" => user.id,
        "logged_in_at" => System.os_time(:second)
      })
      |> live(~p"/settings")

    # (The form isn't shown at all; a forged event changes nothing.)
    render_hook(view, "change_password", %{
      "current_password" => "correct horse 1",
      "new_password" => "another horse 2",
      "confirm_password" => "another horse 2"
    })

    assert {:ok, _} = Users.authenticate("pwuser", "correct horse 1")
  end

  test "admins can't create password accounts", %{conn: conn} do
    {:ok, admin} =
      Users.create_user(%{username: "boss", email: "boss@example.com", password: "boss horse 12"})

    {:ok, admin} = Users.update_user_role(admin, "admin")

    {:ok, view, html} =
      conn
      |> Plug.Test.init_test_session(%{
        "user_id" => admin.id,
        "logged_in_at" => System.os_time(:second)
      })
      |> live(~p"/admin/users")

    assert html =~ "rulemaven-users"
    refute html =~ "create-user-form"

    render_hook(view, "create_user", %{
      "new_username" => "newbie",
      "new_email" => "n@example.com",
      "new_role" => "user"
    })

    refute Users.get_user_by_username("newbie")
  end

  test "an old password session survives the switch for a while, then must use sign-on", %{
    conn: conn,
    user: user
  } do
    now = System.os_time(:second)

    recent =
      conn
      |> Plug.Test.init_test_session(%{"user_id" => user.id, "logged_in_at" => now - 86_400})
      |> get(~p"/settings")

    assert html_response(recent, 200) =~ "Link your Low-Cal Calzone Zone account"

    stale =
      build_conn()
      |> Plug.Test.init_test_session(%{"user_id" => user.id, "logged_in_at" => now - 31 * 86_400})
      |> get(~p"/settings")

    assert redirected_to(stale) == ~p"/login"
  end

  test "with sign-on off, the password routes work as before", %{conn: conn} do
    Application.delete_env(:rule_maven, :oidc)

    conn =
      post(conn, ~p"/login", session: %{"username" => "pwuser", "password" => "correct horse 1"})

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_id)
    assert html_response(get(build_conn(), ~p"/reset-password"), 200)
  end
end
