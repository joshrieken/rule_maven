defmodule RuleMavenWeb.AuthPlug do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)
    user = if user_id, do: RuleMaven.Users.get_user(user_id), else: nil
    # A suspended account is treated as logged out everywhere downstream.
    user = if user && RuleMaven.Users.suspended?(user), do: nil, else: user
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
        |> put_flash(:error, "Please log in first.")
        |> redirect(to: "/login")
        |> halt()
    end
  end

  def logged_in?(conn) do
    user = conn.assigns[:current_user]
    user != nil
  end
end
