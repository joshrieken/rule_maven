defmodule RuleMavenWeb.HubControllerTest do
  # The hub secret is global config (Application env): not async.
  use RuleMavenWeb.ConnCase, async: false

  alias RuleMaven.Users

  setup do
    Application.put_env(:rule_maven, :hub_secret, "hub-secret-value")
    on_exit(fn -> Application.delete_env(:rule_maven, :hub_secret) end)

    {:ok, user} =
      Users.create_user(%{username: "alice", email: "a@example.com", password: "correct horse 1"})

    {:ok, user} = RuleMaven.Auth.SignOn.link_user(user, "sub-alice")
    %{user: user}
  end

  defp hub(conn, query, secret \\ "hub-secret-value") do
    conn
    |> put_req_header("authorization", "Bearer #{secret}")
    |> get("/api/hub/summary", query)
  end

  test "returns the summary as JSON, never cached", %{conn: conn} do
    conn = hub(conn, %{"sub" => "sub-alice"})

    assert %{
             "level" => 0,
             "active" => false,
             "headline" => "No questions yet. Pick a game and ask.",
             "version" => version,
             "updated" => updated
           } = json_response(conn, 200)

    assert version == RuleMaven.Changelog.app_version()
    assert is_boolean(updated)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "401 without the right secret, and always while it's unset", %{conn: conn} do
    assert json_response(hub(conn, %{"sub" => "sub-alice"}, "wrong"), 401)
    assert json_response(get(build_conn(), "/api/hub/summary", %{"sub" => "sub-alice"}), 401)

    Application.delete_env(:rule_maven, :hub_secret)
    assert json_response(hub(build_conn(), %{"sub" => "sub-alice"}, ""), 401)
    assert json_response(hub(build_conn(), %{"sub" => "sub-alice"}), 401)
  end

  test "400 for a missing or oversize sub", %{conn: conn} do
    assert json_response(hub(conn, %{}), 400)
    assert json_response(hub(build_conn(), %{"sub" => ""}), 400)
    assert json_response(hub(build_conn(), %{"sub" => String.duplicate("x", 256)}), 400)
  end

  test "404 for an unknown or suspended person", %{conn: conn, user: user} do
    assert json_response(hub(conn, %{"sub" => "sub-nobody"}), 404)
    {:ok, _} = Users.suspend_user(user)
    assert json_response(hub(build_conn(), %{"sub" => "sub-alice"}), 404)
  end
end
