defmodule RuleMavenWeb.SilentSignInTest do
  # Sign-on config is global (Application env): not async.
  use RuleMavenWeb.ConnCase, async: false

  alias RuleMaven.Auth.Oidc
  alias RuleMaven.{FakeOidc, Repo, Users}
  alias RuleMaven.Users.User
  alias RuleMavenWeb.SilentSignIn

  @cookie "rulemaven_sso_tried"

  setup do
    FakeOidc.configure(name: "Low-Cal Calzone Zone")
    :ok
  end

  # A browser opening a page by hand (top-level navigation).
  defp navigation(conn \\ build_conn()) do
    conn
    |> put_req_header("sec-fetch-mode", "navigate")
    |> put_req_header("sec-fetch-dest", "document")
    |> put_req_header("accept", "text/html,application/xhtml+xml")
  end

  defp tried(conn), do: put_req_cookie(conn, @cookie, "1")

  defp silent_to(next), do: "/auth/oidc/silent?" <> URI.encode_query(%{"next" => next})

  defp claims(sub, groups) do
    %{"sub" => sub, "groups" => groups, "preferred_username" => "alice", "name" => "Alice"}
  end

  defp error_flash(conn), do: Phoenix.Flash.get(conn.assigns.flash, :error)
  defp info_flash(conn), do: Phoenix.Flash.get(conn.assigns.flash, :info)

  # GET /auth/oidc/silent → the provider's authorize URL; returns the conn and its query params.
  defp start_silent(conn, next) do
    conn = get(conn, "/auth/oidc/silent", %{"next" => next})
    url = redirected_to(conn, 302)
    assert String.starts_with?(url, "https://id.test/application/o/authorize/?")
    {conn, URI.decode_query(URI.parse(url).query)}
  end

  describe "trigger" do
    test "a signed-out page load goes to the silent sign-in, keeping the path and query" do
      conn = navigation() |> get("/games/abc?tab=faq")
      assert redirected_to(conn) == silent_to("/games/abc?tab=faq")
      refute error_flash(conn)

      assert navigation() |> get("/") |> redirected_to() == silent_to("/")
    end

    test "Accept: text/html counts when the browser sends no sec-fetch headers" do
      conn = build_conn() |> put_req_header("accept", "text/html") |> get("/settings")
      assert redirected_to(conn) == silent_to("/settings")
    end

    test "also from /changelog and the cheat sheets, which need signing in" do
      assert navigation() |> get("/changelog") |> redirected_to() == silent_to("/changelog")

      assert navigation() |> get("/games/abc/cheatsheet") |> redirected_to() ==
               silent_to("/games/abc/cheatsheet")
    end

    test "a top-level load some browsers label sec-fetch-dest empty still counts" do
      conn =
        build_conn(:get, "/")
        |> put_req_header("sec-fetch-mode", "navigate")
        |> put_req_header("sec-fetch-dest", "empty")

      assert SilentSignIn.silent_path(conn) == "/auth/oidc/silent?next=%2F"
    end

    test "not once tried: the cookie sends people to /login as before" do
      conn = navigation() |> tried() |> get("/")
      assert redirected_to(conn) == ~p"/login"

      conn = navigation() |> tried() |> get("/changelog")
      assert redirected_to(conn) == ~p"/login"
      assert error_flash(conn) =~ "Please log in"
    end

    test "not for requests that aren't page navigations" do
      for headers <- [
            [{"accept", "application/json"}],
            [{"sec-fetch-mode", "cors"}, {"accept", "text/html"}],
            [{"sec-fetch-mode", "no-cors"}, {"sec-fetch-dest", "image"}],
            [{"sec-fetch-mode", "navigate"}, {"sec-fetch-dest", "iframe"}],
            []
          ] do
        conn =
          Enum.reduce(
            headers,
            build_conn(:get, "/"),
            &put_req_header(&2, elem(&1, 0), elem(&1, 1))
          )

        refute SilentSignIn.silent_path(conn), inspect(headers)
      end

      # A fetch of a page that needs signing in (no navigation headers): /login as before.
      assert build_conn() |> get("/") |> redirected_to() == ~p"/login"
    end

    test "not for a POST, the provider's own paths, /login, /health, assets or LiveView" do
      for path <- [
            "/auth/oidc/callback",
            "/login",
            "/health",
            "/live/websocket",
            "/assets/app.js",
            "/api/hub/summary"
          ] do
        conn = %{navigation() | method: "GET", request_path: path, path_info: split(path)}
        refute SilentSignIn.silent_path(conn), path
      end

      conn = %{navigation() | method: "POST", request_path: "/", path_info: []}
      refute SilentSignIn.silent_path(conn)
    end

    test "not without sign-on: today's pages" do
      Application.delete_env(:rule_maven, :oidc)
      assert navigation() |> get("/") |> redirected_to() == ~p"/login"
    end

    test "not for someone signed in" do
      {:ok, user} =
        Users.create_user(%{username: "bob", email: "b@x.test", password: "correct horse 1"})

      now = System.os_time(:second)

      conn =
        navigation()
        |> Plug.Test.init_test_session(%{
          "user_id" => user.id,
          "logged_in_at" => now,
          "sso_until" => now + 60
        })
        |> get("/settings")

      assert html_response(conn, 200)
    end

    test "public pages stay public" do
      assert navigation() |> get("/help") |> html_response(200)
      assert navigation() |> get("/login") |> html_response(200)
    end
  end

  describe "next validation" do
    test "keeps a relative path" do
      assert SilentSignIn.safe_next("/games/1?tab=faq#x") == "/games/1?tab=faq#x"
      assert SilentSignIn.safe_next("/") == "/"
    end

    test "refuses anything that could leave the site" do
      for bad <- [
            "//evil.example",
            "//evil.example/path",
            "/\\evil.example",
            "\\\\evil.example",
            "https://evil.example",
            "javascript:alert(1)",
            "evil.example",
            "",
            "/ok\nLocation: https://evil.example",
            "/\t/evil.example",
            "/" <> String.duplicate("a", 2001),
            nil,
            ["/"],
            %{"a" => "/"}
          ] do
        assert SilentSignIn.safe_next(bad) == "/", inspect(bad)
      end
    end

    test "the silent start carries only a safe next" do
      {conn, _params} = start_silent(build_conn(), "//evil.example")
      assert get_session(conn, :oidc_pending)["next"] == "/"
    end
  end

  describe "GET /auth/oidc/silent" do
    test "asks the provider with prompt=none and sets the tried cookie" do
      {conn, params} = start_silent(build_conn(), "/games/1")

      assert params["prompt"] == "none"
      assert params["code_challenge_method"] == "S256"
      assert params["redirect_uri"] == Oidc.redirect_uri()

      pending = get_session(conn, :oidc_pending)
      assert pending["state"] == params["state"]
      assert pending["nonce"] == params["nonce"]
      assert pending["silent"] == true
      assert pending["next"] == "/games/1"

      cookie = conn.resp_cookies[@cookie]
      assert cookie.value == "1"
      assert cookie.max_age == 600
      assert cookie.http_only
      assert cookie.same_site == "Lax"
      assert cookie.path == "/"
    end

    test "the button's sign-in never sends prompt=none" do
      conn = post(build_conn(), ~p"/auth/oidc", %{"mode" => "login"})
      query = URI.decode_query(URI.parse(redirected_to(conn, 302)).query)
      refute Map.has_key?(query, "prompt")
    end

    test "without sign-on goes to /login" do
      Application.delete_env(:rule_maven, :oidc)
      conn = get(build_conn(), "/auth/oidc/silent", %{"next" => "/games/1"})
      assert redirected_to(conn) == ~p"/login"
      assert conn.resp_cookies[@cookie]
    end
  end

  describe "callback of a silent attempt" do
    test "a provider error returns quietly to /login, and the cookie stops a loop" do
      for error <- ~w(login_required consent_required interaction_required access_denied) do
        {conn, params} = start_silent(build_conn(), "/games/1")

        conn =
          get(conn, ~p"/auth/oidc/callback", %{"error" => error, "state" => params["state"]})

        assert redirected_to(conn) == ~p"/login", error
        refute error_flash(conn), error
        refute get_session(conn, :user_id)

        # Back on a page: the tried cookie (set at the start) means /login, not the provider.
        conn = conn |> recycle() |> navigation() |> get("/games/1")
        assert redirected_to(conn) == ~p"/login"
      end
    end

    test "any other failure is quiet too (refused group, forged state, no attempt)" do
      {conn, params} = start_silent(build_conn(), "/games/1")

      FakeOidc.issue_code("code-1",
        challenge: params["code_challenge"],
        nonce: params["nonce"],
        claims: claims("sub-1", ["other-app-users"])
      )

      conn = get(conn, ~p"/auth/oidc/callback", %{"code" => "code-1", "state" => params["state"]})
      assert redirected_to(conn) == ~p"/login"
      refute error_flash(conn)
      refute Repo.get_by(User, oidc_sub: "sub-1")

      {conn, _params} = start_silent(build_conn(), "/games/1")
      conn = get(conn, ~p"/auth/oidc/callback", %{"code" => "x", "state" => "forged"})
      assert redirected_to(conn) == ~p"/login"
      refute error_flash(conn)
    end

    test "success signs in as usual and returns to next" do
      {conn, params} = start_silent(build_conn(), "/games/1?tab=faq")

      FakeOidc.issue_code("code-1",
        challenge: params["code_challenge"],
        nonce: params["nonce"],
        claims: claims("sub-1", ["rulemaven-admins"])
      )

      conn = get(conn, ~p"/auth/oidc/callback", %{"code" => "code-1", "state" => params["state"]})

      assert redirected_to(conn) == "/games/1?tab=faq"
      user = Repo.get_by!(User, oidc_sub: "sub-1")
      assert user.role == "admin"
      assert get_session(conn, :user_id) == user.id
      assert_in_delta get_session(conn, :sso_until), System.os_time(:second) + 7 * 86_400, 5
      assert conn.resp_cookies["_rule_maven_oidc_id"].max_age == 7 * 86_400
      refute info_flash(conn)
      refute get_session(conn, :oidc_pending)
    end

    test "a tampered next in the session still can't leave the site" do
      {conn, params} = start_silent(build_conn(), "/games/1")
      pending = %{get_session(conn, :oidc_pending) | "next" => "//evil.example"}

      FakeOidc.issue_code("code-1",
        challenge: params["code_challenge"],
        nonce: params["nonce"],
        claims: claims("sub-1", ["rulemaven-users"])
      )

      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(%{"oidc_pending" => pending})
        |> get(~p"/auth/oidc/callback", %{"code" => "code-1", "state" => params["state"]})

      assert redirected_to(conn) == "/"
    end
  end

  describe "sign-out" do
    test "sets the tried cookie" do
      conn = get(build_conn(), ~p"/logout")
      assert conn.resp_cookies[@cookie].value == "1"
      assert conn.resp_cookies[@cookie].max_age == 600
    end
  end

  defp split(path), do: String.split(path, "/", trim: true)
end
