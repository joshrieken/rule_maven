defmodule RuleMavenWeb.LiveSessions do
  @moduledoc """
  Rule Maven's binding of `Lccz.LiveSessions`: a person's open LiveView pages are tied to them
  (`live_socket_id` at every sign-in), so ending their sessions (sign out everywhere, an admin's
  force-logout) also closes pages already open.
  """

  @doc "The session's `live_socket_id` for this person."
  defdelegate id(user_id), to: Lccz.LiveSessions

  @doc "Closes every open LiveView page of this person."
  def disconnect(%{id: user_id}), do: Lccz.LiveSessions.disconnect(RuleMavenWeb.Endpoint, user_id)
end
