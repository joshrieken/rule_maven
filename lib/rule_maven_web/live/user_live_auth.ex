defmodule RuleMavenWeb.UserLiveAuth do
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]
  import Plug.Conn, only: [get_session: 2]

  def on_mount(:default, _params, session, socket) do
    case session[:user_id] || session["user_id"] do
      nil ->
        {:halt, redirect(socket, to: "/login")}

      user_id ->
        user = RuleMaven.Users.get_user(user_id)
        {:cont, assign(socket, :current_user, user)}
    end
  end

  def on_mount(:admin, _params, session, socket) do
    case session[:user_id] || session["user_id"] do
      nil ->
        {:halt, redirect(socket, to: "/login")}

      user_id ->
        user = RuleMaven.Users.get_user(user_id)

        if RuleMaven.Users.game_master?(user) do
          {:cont, assign(socket, :current_user, user)}
        else
          {:halt, redirect(socket, to: "/")}
        end
    end
  end

  def on_mount(:public, _params, session, socket) do
    user =
      case session[:user_id] || session["user_id"] do
        nil -> nil
        user_id -> RuleMaven.Users.get_user(user_id)
      end

    {:cont, assign(socket, :current_user, user)}
  end

  def get_session(conn) do
    %{"user_id" => get_session(conn, :user_id)}
  end
end
