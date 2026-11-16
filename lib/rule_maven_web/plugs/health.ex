defmodule RuleMavenWeb.Plugs.Health do
  @moduledoc """
  `GET /health`, answered before sessions, the router and the database. From
  inside the container (loopback: the Docker healthcheck, `scripts/deploy.sh`,
  which waits until it reports the version it just built) → `{"version": "x.y.z"}`.
  From anywhere else → `{"status": "ok"}`: the running version is for signed-in
  users only. Runs before `Plugs.ClientIp`, so `remote_ip` is the raw TCP peer
  (Traefik for public traffic, never loopback).
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["health"]} = conn, _opts) do
    body =
      if loopback?(conn.remote_ip),
        do: %{version: RuleMaven.Changelog.app_version()},
        else: %{status: "ok"}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
    |> halt()
  end

  def call(conn, _opts), do: conn

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, _}), do: true
  defp loopback?(_), do: false
end
