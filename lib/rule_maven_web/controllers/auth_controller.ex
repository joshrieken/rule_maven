defmodule RuleMavenWeb.AuthController do
  use RuleMavenWeb, :controller

  def logout(conn, _params) do
    conn
    |> delete_session(:user_id)
    |> put_flash(:info, "Logged out.")
    |> redirect(to: ~p"/")
  end

  def auto_login(conn, %{"token" => token}) do
    case Phoenix.Token.verify(conn, "auto-login", token, max_age: 60) do
      {:ok, user_id} ->
        conn
        |> put_session(:user_id, user_id)
        |> put_session(:logged_in_at, System.os_time(:second))
        |> put_flash(:info, "Welcome! Your account is ready.")
        |> redirect(to: ~p"/")

      {:error, _} ->
        conn
        |> put_flash(:error, "Login link expired. Please log in.")
        |> redirect(to: ~p"/login")
    end
  end
end
