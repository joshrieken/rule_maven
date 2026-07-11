defmodule RuleMavenWeb.PageControllerTest do
  use RuleMavenWeb.ConnCase, async: true

  test "GET / redirects to login when unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/login"
  end
end
