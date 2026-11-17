defmodule RuleMavenWeb.LiveSessions do
  @moduledoc """
  Ties a person's open LiveView pages to them (`live_socket_id`, put in the session at every
  sign-in), so ending their sessions (sign out everywhere, an admin's force-logout) also closes
  pages already open: each reconnects, finds the session ended, and goes to /login. Without this an
  open page kept showing until the next click.
  """

  @doc "The session's `live_socket_id` for this person."
  def id(user_id), do: "users_sessions:#{user_id}"

  @doc "Closes every open LiveView page of this person."
  def disconnect(%{id: user_id}),
    do: RuleMavenWeb.Endpoint.broadcast(id(user_id), "disconnect", %{})
end
