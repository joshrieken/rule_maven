defmodule RuleMavenWeb.AuthPlug do
  @moduledoc """
  Loads the session's user into `:current_user` (nil when signed out, suspended,
  force-logged-out or past `RuleMavenWeb.SessionLifetime`). `require_admin/2` gates a route.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias RuleMavenWeb.SessionLifetime

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)
    logged_in_at = get_session(conn, :logged_in_at)
    user = if user_id, do: RuleMaven.Users.get_user(user_id), else: nil

    # A suspended account, or a session revoked by force-logout, is treated as
    # logged out everywhere downstream.
    user =
      cond do
        user && RuleMaven.Users.suspended?(user) -> nil
        user && not RuleMaven.Users.session_valid?(user, logged_in_at) -> nil
        user && not SessionLifetime.valid?(get_session(conn, :sso_until), logged_in_at) -> nil
        true -> user
      end

    assign(conn, :current_user, user)
  end

  def require_admin(conn, _opts) do
    user = conn.assigns[:current_user]

    cond do
      user && RuleMaven.Users.can?(user, :admin) ->
        conn

      user ->
        conn
        |> put_flash(:error, "You don't have permission to do that.")
        |> redirect(to: "/")
        |> halt()

      true ->
        conn
        |> RuleMavenWeb.SilentSignIn.send_to_login("Please log in first.")
        |> halt()
    end
  end

  def logged_in?(conn) do
    user = conn.assigns[:current_user]
    user != nil
  end
end
