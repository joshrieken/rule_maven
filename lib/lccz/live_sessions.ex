defmodule Lccz.LiveSessions do
  @moduledoc """
  Ties a person's open LiveView pages to them (`live_socket_id`, put in the session at every
  sign-in), so ending their sessions (sign out everywhere, an admin's force-logout) also closes
  pages already open: each reconnects, finds the session ended, and goes to /login.
  """

  @doc "The session's `live_socket_id` for this person."
  def id(user_id), do: "users_sessions:#{user_id}"

  @doc "Closes every open LiveView page of this person (`endpoint`: the app's Phoenix endpoint)."
  def disconnect(endpoint, user_id), do: endpoint.broadcast(id(user_id), "disconnect", %{})
end
