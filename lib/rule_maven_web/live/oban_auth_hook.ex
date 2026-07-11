defmodule RuleMavenWeb.ObanAuthHook do
  @moduledoc """
  LiveView on_mount hook for Oban dashboard. Only allows super admins — the
  job runtime UI can retry/cancel/delete any job across the whole app,
  including ones enqueued by other users' actions, so it sits above the
  regular-admin floor like the other raw-power admin pages.
  Reads user from browser session (set by AuthPlug).
  """
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2]

  def on_mount(:default, _params, session, socket) do
    user_id = session["user_id"]

    user = if user_id, do: RuleMaven.Users.get_user(user_id), else: nil

    if user && RuleMaven.Users.can?(user, :superadmin) do
      {:cont, assign(socket, current_user: user)}
    else
      {:halt, redirect(socket, to: "/")}
    end
  end
end
