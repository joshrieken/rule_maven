defmodule RuleMavenWeb.Plugs.HealthTest do
  use RuleMavenWeb.ConnCase, async: true

  test "GET /health from inside the container answers the VERSION file's version", %{
    conn: conn
  } do
    conn = get(conn, "/health")
    # VERSION, not Application.spec(:vsn): the .app only refreshes when mix.exs changes.
    assert json_response(conn, 200) == %{"version" => String.trim(File.read!("VERSION"))}
  end

  test "GET /health from anywhere else says ok without the version", %{conn: conn} do
    # Traefik (plain and IPv4-mapped, as Bandit reports it) and a public address.
    for peer <- [{172, 18, 0, 2}, {0, 0, 0, 0, 0, 0xFFFF, 0xAC12, 2}, {203, 0, 113, 9}] do
      conn = conn |> Map.put(:remote_ip, peer) |> get("/health")
      assert json_response(conn, 200) == %{"status" => "ok"}
    end
  end
end
