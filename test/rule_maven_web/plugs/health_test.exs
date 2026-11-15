defmodule RuleMavenWeb.Plugs.HealthTest do
  use RuleMavenWeb.ConnCase, async: true

  test "GET /health answers the running version as JSON", %{conn: conn} do
    conn = get(conn, "/health")

    assert json_response(conn, 200) == %{
             "version" => to_string(Application.spec(:rule_maven, :vsn))
           }
  end
end
