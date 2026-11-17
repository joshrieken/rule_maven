defmodule RuleMavenWeb.OidcControllerTest do
  # Sign-on config is global (Application env): not async.
  use RuleMavenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest, only: [live: 2]

  alias RuleMaven.{FakeOidc, Repo, Users}
  alias RuleMaven.Users.User

  setup do
    FakeOidc.configure(name: "Low-Cal Calzone Zone")
    :ok
  end

  defp password_user(attrs \\ %{}) do
    {:ok, user} =
      %{username: "alice", email: "alice@example.com", password: "correct horse 1"}
      |> Map.merge(attrs)
      |> Users.create_user()

    user
  end

  defp signed_in(conn, user) do
    Plug.Test.init_test_session(conn, %{
      "user_id" => user.id,
      "logged_in_at" => System.os_time(:second)
    })
  end

  # POST /auth/oidc → the provider's authorize URL; returns the conn and its query params.
  defp start(conn, mode \\ "login") do
    conn = post(conn, ~p"/auth/oidc", %{"mode" => mode})
    url = redirected_to(conn, 302)
    assert String.starts_with?(url, "https://id.test/application/o/authorize/?")
    {conn, URI.decode_query(URI.parse(url).query)}
  end

  # Completes a sign-in as the provider would, for these claims. `tamper` adjusts what the
  # provider registers (challenge/nonce/key) or the callback's params, to simulate attacks.
  defp sign_in(conn, claims, opts \\ []) do
    {conn, params} = start(conn, Keyword.get(opts, :mode, "login"))

    FakeOidc.issue_code(
      "code-1",
      Keyword.merge(
        [challenge: params["code_challenge"], nonce: params["nonce"], claims: claims],
        Keyword.get(opts, :provider, [])
      )
    )

    query = Map.merge(%{"code" => "code-1", "state" => params["state"]}, opts[:callback] || %{})
    get(conn, ~p"/auth/oidc/callback", query)
  end

  defp claims(sub, groups, extra \\ %{}) do
    Map.merge(
      %{"sub" => sub, "groups" => groups, "preferred_username" => "alice", "name" => "Alice"},
      extra
    )
  end

  defp error_flash(conn), do: Phoenix.Flash.get(conn.assigns.flash, :error)

  describe "login page" do
    test "offers only the sign-on button", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)
      assert html =~ "Sign in with Low-Cal Calzone Zone"
      assert html =~ ~s(action="/auth/oidc")
      refute html =~ ~s(name="session[password]")
      refute html =~ "Forgot your password?"
      refute html =~ "/register"
    end

    test "says just \"Sign in\" without a configured name", %{conn: conn} do
      FakeOidc.configure()
      html = conn |> get(~p"/login") |> html_response(200)
      assert html =~ ~r/>\s*Sign in\s*</
      refute html =~ "Sign in with"
    end

    test "without sign-on, the password form is back", %{conn: conn} do
      Application.delete_env(:rule_maven, :oidc)
      html = conn |> get(~p"/login") |> html_response(200)
      assert html =~ ~s(name="session[password]")
      refute html =~ ~s(action="/auth/oidc")
    end
  end

  describe "start" do
    test "sends the browser to the provider with PKCE (S256), state and nonce", %{conn: conn} do
      {conn, params} = start(conn)

      assert params["response_type"] == "code"
      assert params["client_id"] == "rulemaven"
      # From configuration (:public_url), never from the request's Host header.
      assert params["redirect_uri"] == RuleMaven.Auth.Oidc.redirect_uri()
      assert params["redirect_uri"] =~ ~r{^http://localhost:\d+/auth/oidc/callback$}
      assert params["code_challenge_method"] == "S256"
      assert byte_size(params["code_challenge"]) == 43
      assert byte_size(params["state"]) >= 32
      assert byte_size(params["nonce"]) >= 32
      assert params["scope"] =~ "openid"
      assert params["scope"] =~ "profile"

      pending = get_session(conn, :oidc_pending)
      assert pending["state"] == params["state"]
      assert pending["nonce"] == params["nonce"]
      refute Map.has_key?(params, "code_verifier")
    end

    test "ignores a spoofed Host header for the redirect URI", %{conn: conn} do
      {_conn, params} = conn |> Map.put(:host, "evil.example") |> start()
      refute params["redirect_uri"] =~ "evil.example"
    end

    test "is not reachable with a GET", %{conn: conn} do
      conn = get(conn, "/auth/oidc")
      assert conn.status == 404
    end

    test "link mode needs a signed-in user", %{conn: conn} do
      conn = post(conn, ~p"/auth/oidc", %{"mode" => "link"})
      assert redirected_to(conn) == ~p"/login"
      assert error_flash(conn) =~ "Sign in first"
    end
  end

  describe "callback: who gets in" do
    test "first sign-in creates a user (not admin) and a 7-day session", %{conn: conn} do
      conn = sign_in(conn, claims("sub-1", ["rulemaven-users"], %{"email" => "a@x.test"}))

      assert redirected_to(conn) == ~p"/"
      user = Repo.get_by!(User, oidc_sub: "sub-1")
      assert user.role == "user"
      assert user.username == "alice"
      assert user.email == "a@x.test"
      assert user.password_hash == ""
      assert user.email_confirmed_at
      assert get_session(conn, :user_id) == user.id
      assert get_session(conn, :live_socket_id) == RuleMavenWeb.LiveSessions.id(user.id)

      now = System.os_time(:second)
      assert_in_delta get_session(conn, :sso_until), now + 7 * 86_400, 5
      assert conn.resp_cookies["_rule_maven_oidc_id"].max_age == 7 * 86_400
      assert conn.resp_cookies["_rule_maven_oidc_id"].http_only
      # Nothing about the sign-in leaks into the URL.
      refute redirected_to(conn) =~ "?"
    end

    test "the next sign-in finds the same user", %{conn: conn} do
      sign_in(conn, claims("sub-1", ["rulemaven-users"]))
      first = Repo.get_by!(User, oidc_sub: "sub-1")

      conn = sign_in(build_conn(), claims("sub-1", ["rulemaven-users"]))
      assert get_session(conn, :user_id) == first.id
      assert Repo.aggregate(User, :count) == 1
    end

    test "never links to an existing account by email or username", %{conn: conn} do
      existing = password_user()

      conn =
        sign_in(
          conn,
          claims("sub-new", ["rulemaven-users"], %{"email" => "ALICE@example.com"})
        )

      created = Repo.get_by!(User, oidc_sub: "sub-new")
      assert created.id != existing.id
      assert get_session(conn, :user_id) == created.id
      assert created.username == "alice-2"
      assert created.email == nil
      assert Repo.get!(User, existing.id).oidc_sub == nil
    end

    test "refuses someone outside both groups, with a clear message", %{conn: conn} do
      conn = sign_in(conn, claims("sub-1", ["other-app-users"]))

      assert redirected_to(conn) == ~p"/login"
      assert error_flash(conn) =~ ~s(isn't allowed in yet)
      assert error_flash(conn) =~ "rulemaven-users"
      refute get_session(conn, :user_id)
      refute Repo.get_by(User, oidc_sub: "sub-1")
    end

    test "refuses a token without groups", %{conn: conn} do
      conn = sign_in(conn, %{"sub" => "sub-1"})
      assert error_flash(conn) =~ ~s(isn't allowed in yet)
      refute get_session(conn, :user_id)
    end

    test "uses the configured group names", %{conn: conn} do
      FakeOidc.configure(group: "rm-players", admin_group: "rm-bosses")
      refused = sign_in(conn, claims("sub-1", ["rulemaven-users"]))
      assert error_flash(refused) =~ "rm-players"

      conn = sign_in(build_conn(), claims("sub-1", ["rm-bosses"]))
      assert Repo.get_by!(User, oidc_sub: "sub-1").role == "admin"
      assert get_session(conn, :user_id)
    end

    test "admin follows the admin group at every sign-in", %{conn: conn} do
      sign_in(conn, claims("sub-1", ["rulemaven-admins"]))
      assert Repo.get_by!(User, oidc_sub: "sub-1").role == "admin"

      sign_in(build_conn(), claims("sub-1", ["rulemaven-users"]))
      assert Repo.get_by!(User, oidc_sub: "sub-1").role == "user"

      sign_in(build_conn(), claims("sub-1", ["rulemaven-users", "rulemaven-admins"]))
      assert Repo.get_by!(User, oidc_sub: "sub-1").role == "admin"
    end

    test "a super admin's role is never changed by the sync", %{conn: conn} do
      owner = password_user()
      {:ok, owner} = Users.set_super_admin(owner, true)
      {:ok, _} = RuleMaven.Auth.SignOn.link_user(owner, "sub-owner")

      conn = sign_in(conn, claims("sub-owner", ["rulemaven-users"]))
      assert get_session(conn, :user_id) == owner.id
      assert Repo.get!(User, owner.id).role == "super_admin"
    end

    test "refuses a suspended account", %{conn: conn} do
      user = password_user()
      {:ok, _} = RuleMaven.Auth.SignOn.link_user(user, "sub-1")
      {:ok, _} = Users.suspend_user(user)

      conn = sign_in(conn, claims("sub-1", ["rulemaven-users"]))
      assert error_flash(conn) =~ "suspended"
      refute get_session(conn, :user_id)
    end
  end

  describe "callback: protocol checks" do
    test "refuses a state mismatch", %{conn: conn} do
      conn = sign_in(conn, claims("sub-1", ["rulemaven-users"]), callback: %{"state" => "forged"})
      assert redirected_to(conn) == ~p"/login"
      assert error_flash(conn) =~ "mixed up"
      refute get_session(conn, :user_id)
      refute Repo.get_by(User, oidc_sub: "sub-1")
    end

    test "refuses a nonce mismatch", %{conn: conn} do
      conn =
        sign_in(conn, claims("sub-1", ["rulemaven-users"]), provider: [nonce: "someone-elses"])

      assert error_flash(conn) =~ "didn't work"
      refute get_session(conn, :user_id)
    end

    test "refuses a PKCE mismatch (the provider rejects the verifier)", %{conn: conn} do
      conn =
        sign_in(conn, claims("sub-1", ["rulemaven-users"]),
          provider: [challenge: "not-the-challenge"]
        )

      assert error_flash(conn) =~ "didn't work"
      refute get_session(conn, :user_id)
    end

    test "refuses an ID token signed by a key the provider doesn't publish", %{conn: conn} do
      conn = sign_in(conn, claims("sub-1", ["rulemaven-users"]), provider: [key: :other])
      assert error_flash(conn) =~ "didn't work"
      refute get_session(conn, :user_id)
    end

    test "refuses an expired ID token, a wrong audience and a wrong issuer", %{conn: conn} do
      past = System.os_time(:second) - 600

      for bad <- [
            %{"exp" => past, "iat" => past - 300},
            %{"aud" => "another-app"},
            %{"iss" => "https://evil.test/"}
          ] do
        c = sign_in(build_conn(), Map.merge(claims("sub-1", ["rulemaven-users"]), bad))
        assert error_flash(c) =~ "didn't work", inspect(bad)
        refute get_session(c, :user_id)
      end

      _ = conn
    end

    test "a callback with no attempt in progress is refused", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc/callback", %{"code" => "x", "state" => "y"})
      assert redirected_to(conn) == ~p"/login"
      assert error_flash(conn) =~ "took too long"
    end

    test "an attempt older than 10 minutes is refused", %{conn: conn} do
      {conn, params} = start(conn)
      pending = get_session(conn, :oidc_pending)
      FakeOidc.issue_code("code-1", challenge: params["code_challenge"], nonce: params["nonce"])

      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(%{
          "oidc_pending" => %{pending | "at" => pending["at"] - 601}
        })
        |> get(~p"/auth/oidc/callback", %{"code" => "code-1", "state" => params["state"]})

      assert error_flash(conn) =~ "took too long"
      refute get_session(conn, :user_id)
    end

    test "each attempt can be used once", %{conn: conn} do
      conn = sign_in(conn, claims("sub-1", ["rulemaven-users"]))
      refute get_session(conn, :oidc_pending)
    end

    test "a provider error shows a flash, not the provider's text in the URL", %{conn: conn} do
      {conn, params} = start(conn)

      conn =
        get(conn, ~p"/auth/oidc/callback", %{
          "error" => "access_denied",
          "error_description" => "<script>",
          "state" => params["state"]
        })

      assert redirected_to(conn) == ~p"/login"
      assert error_flash(conn) =~ "said no"
    end
  end

  describe "linking an existing account" do
    test "a signed-in password user links, and later sign-ins land in that account", %{
      conn: conn
    } do
      user = password_user()

      conn =
        conn
        |> signed_in(user)
        |> sign_in(claims("sub-alice", ["rulemaven-users"]), mode: "link")

      assert redirected_to(conn) == ~p"/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Linked"
      assert Repo.get!(User, user.id).oidc_sub == "sub-alice"

      conn = sign_in(build_conn(), claims("sub-alice", ["rulemaven-users"]))
      assert get_session(conn, :user_id) == user.id
      assert Repo.aggregate(User, :count) == 1
    end

    test "refuses a sign-on account that already belongs to someone else", %{conn: conn} do
      other = password_user(%{username: "bob", email: "bob@example.com"})
      {:ok, _} = RuleMaven.Auth.SignOn.link_user(other, "sub-taken")
      user = password_user()

      conn =
        conn
        |> signed_in(user)
        |> sign_in(claims("sub-taken", ["rulemaven-users"]), mode: "link")

      assert redirected_to(conn) == ~p"/settings"
      assert error_flash(conn) =~ "already linked"
      assert Repo.get!(User, user.id).oidc_sub == nil
    end

    test "linking still needs the group", %{conn: conn} do
      user = password_user()

      conn =
        conn
        |> signed_in(user)
        |> sign_in(claims("sub-alice", []), mode: "link")

      assert error_flash(conn) =~ ~s(isn't allowed in yet)
      assert Repo.get!(User, user.id).oidc_sub == nil
    end

    test "the Settings page offers the link button until linked", %{conn: conn} do
      user = password_user()
      {:ok, _view, html} = conn |> signed_in(user) |> live(~p"/settings")
      assert html =~ "Link your Low-Cal Calzone Zone account"
      refute html =~ ~s(name="new_password")

      {:ok, _} = RuleMaven.Auth.SignOn.link_user(user, "sub-alice")
      {:ok, _view, html} = build_conn() |> signed_in(user) |> live(~p"/settings")
      refute html =~ "Link your Low-Cal Calzone Zone account"
      assert html =~ "You sign in with your Low-Cal Calzone Zone account"
    end
  end

  describe "sign-out" do
    test "ends the provider's session too, returning to /login", %{conn: conn} do
      conn = sign_in(conn, claims("sub-1", ["rulemaven-users"]))
      conn = get(conn, ~p"/logout")

      url = redirected_to(conn, 302)
      assert String.starts_with?(url, FakeOidc.end_session_endpoint() <> "?")
      query = URI.decode_query(URI.parse(url).query)
      assert query["post_logout_redirect_uri"] == RuleMaven.Auth.Oidc.post_logout_redirect_uri()
      assert query["post_logout_redirect_uri"] =~ ~r{/login$}
      assert [_, _, _] = String.split(query["id_token_hint"], ".")
      refute get_session(conn, :user_id)
      assert conn.resp_cookies["_rule_maven_oidc_id"].max_age == 0
    end

    test "without a kept ID token it just signs out here", %{conn: conn} do
      conn = conn |> signed_in(password_user()) |> get(~p"/logout")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_id)
    end
  end

  describe "session lifetime" do
    test "a sign-on session ends after 7 days", %{conn: conn} do
      user = password_user()
      now = System.os_time(:second)

      fresh =
        conn
        |> Plug.Test.init_test_session(%{
          "user_id" => user.id,
          "logged_in_at" => now,
          "sso_until" => now + 60
        })
        |> get(~p"/settings")

      assert html_response(fresh, 200)

      expired =
        build_conn()
        |> Plug.Test.init_test_session(%{
          "user_id" => user.id,
          "logged_in_at" => now - 8 * 86_400,
          "sso_until" => now - 86_400
        })
        |> get(~p"/settings")

      assert redirected_to(expired) == ~p"/login"
    end
  end

  describe "back-channel logout (sign out everywhere)" do
    @event %{"http://schemas.openid.net/event/backchannel-logout" => %{}}

    defp linked_user(sub) do
      {:ok, user} =
        RuleMaven.Auth.SignOn.sign_in(
          %{"sub" => sub, "groups" => ["rulemaven-users"], "preferred_username" => sub},
          group: "rulemaven-users",
          admin_group: "rulemaven-admins"
        )

      user
    end

    defp notify(conn, token),
      do: post(conn, ~p"/auth/oidc/backchannel", %{"logout_token" => token})

    test "ends that person's sessions here, and only theirs", %{conn: conn} do
      jo = linked_user("sub-jo")
      kim = linked_user("sub-kim")
      before = System.os_time(:second) - 5
      RuleMavenWeb.Endpoint.subscribe(RuleMavenWeb.LiveSessions.id(jo.id))

      assert notify(conn, FakeOidc.id_token(%{"sub" => "sub-jo", "events" => @event})).status ==
               200

      # Their open pages close (and reconnect to /login).
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      refute Users.session_valid?(Repo.get!(User, jo.id), before)
      assert Users.session_valid?(Repo.get!(User, kim.id), before)
      # The sign-in page's header doesn't show them either (it used to read the cookie unchecked).
      html = build_conn() |> signed_in_at(jo, before) |> get(~p"/login") |> html_response(200)
      refute html =~ jo.username

      # A signed-in page from before is signed out now.
      assert build_conn() |> signed_in_at(jo, before) |> get(~p"/settings") |> redirected_to() =~
               "/login"
    end

    test "refuses tokens that aren't logout tokens from the provider", %{conn: conn} do
      jo = linked_user("sub-jo")
      before = System.os_time(:second) - 5

      for token <- [
            FakeOidc.id_token(%{"sub" => "sub-jo"}),
            FakeOidc.id_token(%{"sub" => "sub-jo", "events" => @event, "nonce" => "n"}),
            FakeOidc.id_token(%{"sub" => "sub-jo", "events" => @event}, :other),
            FakeOidc.id_token(%{"sub" => "sub-jo", "events" => @event, "aud" => "drawburn"}),
            "not a token"
          ] do
        assert notify(conn, token).status == 400
      end

      assert notify(conn, nil).status == 400
      assert Users.session_valid?(Repo.get!(User, jo.id), before)
    end

    test "is quiet about someone it doesn't know", %{conn: conn} do
      assert notify(conn, FakeOidc.id_token(%{"sub" => "nobody", "events" => @event})).status ==
               200
    end
  end

  defp signed_in_at(conn, user, at) do
    Plug.Test.init_test_session(conn, %{"user_id" => user.id, "logged_in_at" => at})
  end
end
