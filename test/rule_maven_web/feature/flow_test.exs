defmodule RuleMavenWeb.Feature.FlowTest do
  use RuleMavenWeb.FeatureCase, async: false

  import RuleMaven.GamesFixtures

  @moduledoc """
  Browser-only flow tests: localStorage-driven theme persistence and the
  app.js collapse toggle on the Prepare page. Server-rendered flow tests
  (login, nav, game list, modal) live in
  test/rule_maven_web/smoke_flow_test.exs (ConnCase/LiveViewTest).
  """

  @password "testpassword123"

  # Helper: log in via form and return session
  # Log in without driving the form. Typing into the login form was flaky: the
  # layout mounts a LiveView that patches the DOM just after connect, so elements
  # captured for fill_in/click went stale (StaleReferenceError), and a not-yet-
  # committed session let the next visit/2 race back to /login. The app already
  # has a signed-token bypass (`/auto-login`, used post-registration) — a plain
  # controller that sets the session and redirects, with no form and no LiveView
  # in the path. Deterministic. We still assert the logged-in header to block
  # until the session is established before returning.
  defp login(session, username) do
    user = RuleMaven.Users.get_user_by_username(username)
    token = Phoenix.Token.sign(RuleMavenWeb.Endpoint, "auto-login", user.id)

    session
    |> visit("/auto-login?token=#{token}")
    |> assert_has(css(".header-user", text: username))
  end

  # Helper: create a user for testing
  defp create_user(username, role) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: username,
        email: "#{username}@test.com",
        password: @password,
        role: role
      })

    # Fresh users autostart the onboarding tour; its spotlight overlay sits on
    # top of the page and swallows the clicks these tests make. Pre-mark every
    # tour as seen so features exercise the page, not the tour.
    seen =
      Map.new(RuleMavenWeb.Tours.ids(), &{&1, DateTime.utc_now() |> DateTime.to_iso8601()})

    user
    |> Ecto.Changeset.change(tours_seen: seen)
    |> RuleMaven.Repo.update!()
  end

  # Stays a browser test: the expand/collapse toggle is client-side app.js
  # (data-prepare-head has no phx-click), so only a real browser covers it.
  feature "admin can open a game's Prepare (readiness) page", %{session: session} do
    user = create_user("e2e_prepare_admin", "admin")
    game = published_game_fixture(%{name: "Prep Test Game", bgg_id: 7777})

    session
    |> login(user.username)
    |> visit("/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")
    |> assert_has(css("h1", text: "Prepare Prep Test Game"))
    |> assert_has(css("button", text: "Prepare game"))
    |> assert_has(css("h2", text: "Pipeline"))
    |> assert_has(css("button[data-prepare-all]", text: "Expand all"))
    # A published fixture has an uploaded source, so its step is collapsible and
    # starts collapsed (no data-open until the admin expands it).
    |> assert_has(css("[data-prepare-step='source']"))
    |> refute_has(css("[data-prepare-step='source'][data-open]"))
    # Expanding reveals the step's result body and its action link.
    |> click(css("[data-prepare-step='source'] [data-prepare-head]"))
    |> assert_has(css("[data-prepare-step='source'][data-open]"))
    |> assert_has(css("[data-prepare-step='source'] a", text: "Manage on edit page"))
  end

  # Stays a browser test: theme persistence is localStorage + the inline
  # theme-migration script in the root layout — no server involvement.
  feature "theme persists across page navigation", %{session: session} do
    session
    |> visit("/login")

    # Set theme via JS. Use a current slug ("deep-space") — retired slugs like
    # "nebula" get rewritten by the theme-migration script on load.
    session
    |> Wallaby.Browser.execute_script("""
      document.documentElement.setAttribute('data-theme', 'deep-space');
      localStorage.setItem('theme', 'deep-space');
    """)

    # Navigate to another page
    session
    |> visit("/login")

    page_source = session |> Wallaby.Browser.page_source()
    assert page_source =~ ~s(data-theme="deep-space")
  end
end
