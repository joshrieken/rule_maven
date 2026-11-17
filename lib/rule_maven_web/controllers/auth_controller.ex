defmodule RuleMavenWeb.AuthController do
  use RuleMavenWeb, :controller

  alias RuleMaven.Auth.Oidc
  alias RuleMavenWeb.{OidcController, SilentSignIn}

  @doc """
  Signs out here and, after a single sign-on, at the provider too (its end-session address with
  the kept ID token; it returns people to /login). Without that, Sign in would go straight back
  in as the same person. Also marks silent sign-in as tried, so the next page doesn't sign
  straight back in.
  """
  def logout(conn, _params) do
    cookie = OidcController.id_token_cookie()
    conn = fetch_cookies(conn, signed: [cookie])
    end_session = Oidc.end_session_url(conn.cookies[cookie])

    conn =
      conn
      |> delete_session(:user_id)
      |> delete_session(:logged_in_at)
      |> delete_session(:sso_until)
      |> delete_resp_cookie(cookie, sign: true, http_only: true, same_site: "Lax")
      |> SilentSignIn.put_tried_cookie()
      |> put_flash(:info, "Logged out.")

    case end_session do
      nil -> redirect(conn, to: ~p"/")
      url -> redirect(conn, external: url)
    end
  end

  def auto_login(conn, %{"token" => token}) do
    case Phoenix.Token.verify(conn, "auto-login", token, max_age: 60) do
      {:ok, user_id} ->
        conn
        |> put_session(:user_id, user_id)
        |> put_session(:live_socket_id, RuleMavenWeb.LiveSessions.id(user_id))
        |> put_session(:logged_in_at, System.os_time(:second))
        |> delete_session(:sso_until)
        |> put_flash(:info, "Welcome! Your account is ready.")
        |> redirect(to: ~p"/")

      {:error, _} ->
        conn
        |> put_flash(:error, "Login link expired. Please log in.")
        |> redirect(to: ~p"/login")
    end
  end
end
