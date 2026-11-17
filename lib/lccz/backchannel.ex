defmodule Lccz.Backchannel do
  @moduledoc """
  Back-channel logout, sign out everywhere (PLATFORM.md §2): the sign-in service POSTs a signed
  logout token to `/auth/oidc/backchannel` (server to server, over the internal network; no
  session, no CSRF token: the token is the check) when someone's session there ends. The app ends
  every session of that person and their open pages follow.

  In the app's router, outside the browser pipeline: `post "/auth/oidc/backchannel", ...` and a
  controller action calling `serve/3`. In production config, exclude the path from `force_ssl`
  (it arrives over plain http on the internal network).
  """

  require Logger

  @doc """
  Answers a back-channel logout. `opts`: `:oidc` (the app's `use Lccz.Oidc` module),
  `:end_sessions` (`fn sub -> {:ok, user_id} | nil end`: end every session of that person),
  `:endpoint` (the app's endpoint: their open LiveView pages close, `Lccz.LiveSessions`).
  200 when done (also for someone unknown), 400 for a token that doesn't check out, 404 when
  sign-on is off.
  """
  @spec serve(Plug.Conn.t(), map(), keyword()) :: Plug.Conn.t()
  def serve(conn, params, opts) do
    oidc = Keyword.fetch!(opts, :oidc)
    conn = Plug.Conn.put_resp_header(conn, "cache-control", "no-store")

    with %Lccz.Oidc.Settings{} = settings <- oidc.settings(),
         {:ok, sub} <- oidc.verify_logout_token(settings, params["logout_token"]) do
      close_pages(opts[:end_sessions].(sub), opts[:endpoint])

      Plug.Conn.send_resp(conn, 200, "")
    else
      nil ->
        Plug.Conn.send_resp(conn, 404, "")

      {:error, reason} ->
        Logger.warning("Back-channel logout refused: #{inspect(reason)}")
        conn |> Plug.Conn.put_status(400) |> Phoenix.Controller.json(%{error: "invalid_request"})
    end
  end

  # Their open LiveView pages reconnect and go to /login (Lccz.LiveSessions).
  defp close_pages({:ok, user_id}, endpoint) when not is_nil(endpoint),
    do: Lccz.LiveSessions.disconnect(endpoint, user_id)

  defp close_pages(_ended, _endpoint), do: :ok
end
