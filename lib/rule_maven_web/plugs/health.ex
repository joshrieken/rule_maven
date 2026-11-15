defmodule RuleMavenWeb.Plugs.Health do
  @moduledoc """
  `GET /health` → `{"version": "x.y.z"}`, answered before sessions, the router
  and the database. The Docker healthcheck and `scripts/deploy.sh` poll it; the
  deploy script waits until it reports the version it just built.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["health"]} = conn, _opts) do
    version = to_string(Application.spec(:rule_maven, :vsn))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{version: version}))
    |> halt()
  end

  def call(conn, _opts), do: conn
end
