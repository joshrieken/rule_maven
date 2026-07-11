defmodule RuleMavenWeb.Feature.FlowTest do
  use RuleMavenWeb.FeatureCase, async: false

  import RuleMaven.GamesFixtures

  @moduledoc """
  End-to-end flow tests: login, game list, auth visibility, theme persistence.
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

  feature "login page renders form", %{session: session} do
    session
    |> visit("/login")
    |> assert_has(css("h1.login-brand"))
    |> assert_has(css("input#session_username"))
    |> assert_has(css("input#session_password"))
    |> assert_has(css("button", text: "Log In"))
  end

  feature "login fails with bad credentials", %{session: session} do
    # fill_in/3 re-queries the element on each call, so a late defer-script
    # touching the DOM can't leave us holding a stale element reference (the
    # reason this test previously needed a Process.sleep after visit).
    session
    |> visit("/login")
    |> fill_in(css("input#session_username"), with: "nonexistent")
    |> fill_in(css("input#session_password"), with: "wrongpassword")
    |> click(css("button", text: "Log In"))
    |> assert_has(css(".alert-error"))
  end

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

  feature "asking page shows an answer-voice selector", %{session: session} do
    user = create_user("e2e_voice_admin", "admin")
    game = published_game_fixture(%{name: "Voice Test Game"})

    session
    |> login(user.username)
    |> visit("/games/#{RuleMaven.Hashid.encode(game.id)}")
    |> assert_has(css("span", text: "Answer persona"))
    |> assert_has(css("button[phx-value-target='default']"))
  end

  feature "suggested questions open in a modal", %{session: session} do
    user = create_user("e2e_suggest_admin", "admin")
    game = published_game_fixture(%{name: "Suggest Test Game"})

    RuleMaven.Settings.put(
      "suggestions_#{game.id}",
      Jason.encode!([%{"category" => "Setup", "questions" => ["How many cards each?"]}])
    )

    session
    |> login(user.username)
    |> visit("/games/#{RuleMaven.Hashid.encode(game.id)}")
    # Modal starts closed (its Close button is absent), opens on the trigger
    # showing the question, and closes again.
    |> refute_has(css("button[aria-label='Close']"))
    # The trigger lives inside the 💡 Ideas disclosure menu — open that first.
    |> click(css("details[data-tour='suggestions'] > summary"))
    |> click(css("button", text: "Suggested questions"))
    |> assert_has(css("button[aria-label='Close']"))
    |> assert_has(css("button", text: "How many cards each?", minimum: 1))
    # Close via the ✕. ChromeDriver's native click on this button is silently
    # swallowed in headless runs (Escape, JS clicks, and real browsers all
    # close fine), so dispatch the click from JS to keep the button's
    # phx-click covered.
    |> then(fn sess ->
      Wallaby.Browser.execute_script(
        sess,
        "document.querySelector(\"button[aria-label='Close']\").click()"
      )
    end)
    |> refute_has(css("button[aria-label='Close']"))
  end

  feature "login succeeds and shows game list", %{session: session} do
    user = create_user("e2e_flow_user", "admin")
    published_game_fixture(%{name: "E2E Test Game", bgg_id: 9999})

    session
    |> login(user.username)

    # After login redirects to / which is the game list
    assert_has(session, css("h2", text: "E2E Test Game"))
  end

  feature "logged-out user sees Log in link", %{session: session} do
    session
    |> visit("/")
    |> assert_has(css(".nav-link", text: "Log in"))
  end

  feature "admin sees admin nav links", %{session: session} do
    user = create_user("e2e_gm_visible", "admin")

    session
    |> login(user.username)
    |> assert_has(css(".nav-link", text: "Dashboard"))
    # The rest of the admin links now live in the "Admin" dropdown.
    |> click(css(".user-dropdown-toggle", text: "Admin"))
    |> assert_has(css(".user-dropdown-link", text: "Takedowns"))
  end

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

  feature "game list shows game metadata when logged in", %{session: session} do
    user = create_user("e2e_meta_user", "admin")

    published_game_fixture(%{
      name: "Meta Test Game",
      bgg_id: 8888,
      year: 2024,
      min_players: 2,
      max_players: 4,
      playing_time: 60
    })

    session
    |> login(user.username)
    |> assert_has(css("h2", text: "Meta Test Game"))
    |> assert_has(css("p.text-sm.text-gray-500"))
  end
end
