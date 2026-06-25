defmodule RuleMavenWeb.Feature.FlowTest do
  use RuleMavenWeb.FeatureCase, async: false

  import RuleMaven.GamesFixtures

  @moduledoc """
  End-to-end flow tests: login, game list, auth visibility, theme persistence.
  """

  @password "testpassword123"

  # Helper: log in via form and return session
  defp login(session, username) do
    session
    |> visit("/login")

    # Wait for page to fully settle (LiveView JS, CSRF, etc.)
    Process.sleep(500)

    Wallaby.Browser.find(session, css("input#session_username"), fn el ->
      Wallaby.Element.fill_in(el, with: username)
    end)

    Wallaby.Browser.find(session, css("input#session_password"), fn el ->
      Wallaby.Element.fill_in(el, with: @password)
    end)

    Wallaby.Browser.find(session, css("button", text: "Log In"), fn el ->
      Wallaby.Element.click(el)
    end)

    session
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

    user
  end

  feature "login page renders form", %{session: session} do
    session
    |> visit("/login")
    |> assert_has(css("h2", text: "Log In"))
    |> assert_has(css("input#session_username"))
    |> assert_has(css("input#session_password"))
    |> assert_has(css("button", text: "Log In"))
  end

  feature "login fails with bad credentials", %{session: session} do
    session
    |> visit("/login")

    Process.sleep(500)

    Wallaby.Browser.find(session, css("input#session_username"), fn el ->
      Wallaby.Element.fill_in(el, with: "nonexistent")
    end)

    Wallaby.Browser.find(session, css("input#session_password"), fn el ->
      Wallaby.Element.fill_in(el, with: "wrongpassword")
    end)

    Wallaby.Browser.find(session, css("button", text: "Log In"), fn el ->
      Wallaby.Element.click(el)
    end)

    assert_has(session, css(".alert-error"))
  end

  feature "login succeeds and shows game list", %{session: session} do
    user = create_user("e2e_flow_user", "game_master")
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

  feature "game master sees admin nav links", %{session: session} do
    user = create_user("e2e_gm_visible", "game_master")

    session
    |> login(user.username)
    |> assert_has(css(".nav-link", text: "Dashboard"))
    |> assert_has(css(".nav-link", text: "Threads"))
  end

  feature "theme persists across page navigation", %{session: session} do
    session
    |> visit("/login")

    Process.sleep(500)

    # Set theme via JS
    session
    |> Wallaby.Browser.execute_script("""
      document.documentElement.setAttribute('data-theme', 'ocean');
      localStorage.setItem('theme', 'ocean');
    """)

    # Navigate to another page
    session
    |> visit("/login")

    page_source = session |> Wallaby.Browser.page_source()
    assert page_source =~ ~s(data-theme="ocean")
  end

  feature "game list shows game metadata when logged in", %{session: session} do
    user = create_user("e2e_meta_user", "game_master")

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
