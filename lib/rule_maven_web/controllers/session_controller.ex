defmodule RuleMavenWeb.SessionController do
  use RuleMavenWeb, :controller

  alias RuleMaven.Auth.Oidc

  def new(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/")
    else
      render(conn, :new, username: "", error: nil, sso: Oidc.settings())
    end
  end

  alias RuleMaven.Auth.LoginThrottle

  def create(conn, %{"session" => %{"username" => username, "password" => password}}) do
    key = LoginThrottle.key(conn.remote_ip, username)

    case LoginThrottle.check(key) do
      {:error, seconds} ->
        render(conn, :new,
          username: username,
          error: "Too many attempts. Try again in #{minutes(seconds)}.",
          sso: nil
        )

      :ok ->
        case RuleMaven.Users.authenticate(username, password) do
          {:ok, user} ->
            LoginThrottle.clear(key)

            conn
            |> put_session(:user_id, user.id)
            |> put_session(:live_socket_id, RuleMavenWeb.LiveSessions.id(user.id))
            |> put_session(:logged_in_at, System.os_time(:second))
            |> delete_session(:sso_until)
            |> put_flash(:info, "Welcome back!")
            |> redirect(to: ~p"/")

          {:error, reason} ->
            LoginThrottle.record_failure(key)
            render(conn, :new, username: username, error: reason, sso: nil)
        end
    end
  end

  defp minutes(seconds) do
    mins = max(1, div(seconds + 59, 60))
    "#{mins} minute#{if mins == 1, do: "", else: "s"}"
  end
end
