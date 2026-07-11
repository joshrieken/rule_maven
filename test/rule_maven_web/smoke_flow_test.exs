defmodule RuleMavenWeb.SmokeFlowTest do
  use RuleMavenWeb.ConnCase, async: true

  @moduledoc """
  Server-rendered smoke and flow assertions that never needed a browser:
  these needed a real browser — they only assert HTML the server produced.
  As LiveViewTest/ConnCase they run in milliseconds instead of seconds and
  can't flake on Chrome. Tests that genuinely exercise browser behavior
  (JS errors, localStorage, computed styles, DOM geometry, the app.js
  collapse toggle on Prepare) stay in test/rule_maven_web/feature/.
  """

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  @password "testpassword123"

  defp create_user(username, role) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: username,
        email: "#{username}@test.com",
        password: @password,
        role: role
      })

    # Fresh users autostart the onboarding tour, whose overlay markup would
    # sit in every render. Pre-mark tours seen so tests assert the page.
    seen =
      Map.new(RuleMavenWeb.Tours.ids(), &{&1, DateTime.utc_now() |> DateTime.to_iso8601()})

    user
    |> Ecto.Changeset.change(tours_seen: seen)
    |> RuleMaven.Repo.update!()
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  describe "smoke: logged-out chrome (root layout, served at /login)" do
    # Anonymous "/" redirects to /login (the old browser versions of these tests
    # followed that redirect transparently); the header, nav, and theme picker
    # live in the root layout, so /login carries them all.
    test "anonymous / redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
    end

    test "page renders with header brand and Log in link", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)
      assert html =~ "header-brand"
      assert html =~ "Log in"
    end

    test "theme selector exists with light and dark options", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)
      assert html =~ ~s(id="theme-select")
      assert html =~ ~s(value="fresh-deck")
      assert html =~ ~s(value="night-owl")
    end
  end

  describe "smoke: login page" do
    test "renders form", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)
      assert html =~ "login-brand"
      assert html =~ ~s(id="session_username")
      assert html =~ ~s(id="session_password")
      assert html =~ "Log In"
    end

    test "renders themed text (theme variables in inline styles)", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)
      assert html =~ "color:var(--text-secondary)"
    end

    test "login fails with bad credentials", %{conn: conn} do
      conn =
        post(conn, ~p"/login", %{
          "session" => %{"username" => "nonexistent", "password" => "wrongpassword"}
        })

      assert html_response(conn, 200) =~ "alert-error"
    end

    test "login succeeds and redirects to game list", %{conn: conn} do
      user = create_user("flow_login_user", "admin")

      conn =
        post(conn, ~p"/login", %{
          "session" => %{"username" => user.username, "password" => @password}
        })

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_id) == user.id
    end
  end

  describe "flow: logged-in game list" do
    test "shows game name and metadata", %{conn: conn} do
      user = create_user("flow_meta_user", "admin")

      published_game_fixture(%{
        name: "Meta Test Game",
        bgg_id: 8888,
        year: 2024,
        min_players: 2,
        max_players: 4,
        playing_time: 60
      })

      {:ok, view, _} = conn |> login(user) |> live(~p"/")
      # The list waits for the search hook's restore_search push before
      # rendering (client-remembered search text); simulate the hook.
      html = render_hook(view, "restore_search", %{"value" => ""})
      assert has_element?(view, "h2", "Meta Test Game")
      assert html =~ "text-gray-500"
    end

    test "admin sees admin nav links (Dashboard + Takedowns in dropdown)", %{conn: conn} do
      user = create_user("flow_admin_nav", "admin")

      # The header nav lives in the root layout, outside the LiveView's render
      # tree, so assert on the full dead-render page instead of has_element?.
      html = conn |> login(user) |> get(~p"/") |> html_response(200)
      assert html =~ "Dashboard"
      # The dropdown is an HTML <details> disclosure; its links are always in
      # the DOM, so asserting presence covers what the browser click revealed.
      assert html =~ "Takedowns"
    end
  end

  describe "flow: game page" do
    test "asking page shows an answer-voice selector", %{conn: conn} do
      user = create_user("flow_voice_admin", "admin")
      game = published_game_fixture(%{name: "Voice Test Game"})

      {:ok, view, _html} =
        conn |> login(user) |> live(~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

      assert has_element?(view, "span", "Answer persona")
      assert has_element?(view, "button[phx-value-target='default']")
    end

    test "suggested questions open in a modal and close again", %{conn: conn} do
      user = create_user("flow_suggest_admin", "admin")
      game = published_game_fixture(%{name: "Suggest Test Game"})

      RuleMaven.Settings.put(
        "suggestions_#{game.id}",
        Jason.encode!([%{"category" => "Setup", "questions" => ["How many cards each?"]}])
      )

      {:ok, view, _html} =
        conn |> login(user) |> live(~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

      # Modal starts closed.
      refute has_element?(view, "button[aria-label='Close']")

      view
      |> element("button[phx-click='open_suggestions']")
      |> render_click()

      assert has_element?(view, "button[aria-label='Close']")
      assert has_element?(view, "button", "How many cards each?")

      view
      |> element("button[aria-label='Close']")
      |> render_click()

      refute has_element?(view, "button[aria-label='Close']")
    end
  end
end
