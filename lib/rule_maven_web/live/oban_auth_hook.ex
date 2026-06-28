defmodule RuleMavenWeb.ObanAuthHook do
  @moduledoc """
  LiveView on_mount hook for Oban dashboard. Only allows admin users.
  Reads user from browser session (set by AuthPlug).
  """
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2]

  def on_mount(:default, _params, session, socket) do
    user_id = session["user_id"]

    user = if user_id, do: RuleMaven.Users.get_user(user_id), else: nil

    if user && RuleMaven.Users.can?(user, :admin) do
      {:cont, assign(socket, current_user: user)}
    else
      {:halt, redirect(socket, to: "/")}
    end
  end
end
