defmodule RuleMavenWeb.Feature.FlowTest do
  use PhoenixTest.Playwright.Case, async: false

  import RuleMaven.GamesFixtures

  # Lets `mix test.fast` skip browser E2E tests.
  @moduletag :feature

  @moduledoc """
  Browser-only flow tests: localStorage-driven theme persistence and the
  app.js collapse toggle on the Prepare page. Server-rendered flow tests
  (login, nav, game list, modal) live in
  test/rule_maven_web/smoke_flow_test.exs (ConnCase/LiveViewTest).
  """

  @password "testpassword123"

  # Log in via the signed-token bypass (`/auto-login`, used post-registration):
  # a plain controller that sets the session and redirects - no form, no
  # LiveView in the path. The logged-in header assert blocks until the session
  # is established.
  defp login(conn, username) do
    user = RuleMaven.Users.get_user_by_username(username)
    token = Phoenix.Token.sign(RuleMavenWeb.Endpoint, "auto-login", user.id)

    conn
    |> visit("/auto-login?token=#{token}")
    |> assert_has(".header-user", text: username)
  end

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
  test "admin can open a game's Prepare (readiness) page", %{conn: conn} do
    user = create_user("e2e_prepare_admin", "admin")
    game = published_game_fixture(%{name: "Prep Test Game", bgg_id: 7777})

    conn
    |> login(user.username)
    |> visit("/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")
    |> assert_has("h1", text: "Prepare Prep Test Game")
    |> assert_has("button", text: "Prepare game")
    |> assert_has("h2", text: "Pipeline")
    |> assert_has("button[data-prepare-all]", text: "Expand all")
    # A published fixture has an uploaded source, so its step is collapsible and
    # starts collapsed (no data-open until the admin expands it).
    |> assert_has("[data-prepare-step='source']")
    |> refute_has("[data-prepare-step='source'][data-open]")
    # Expanding reveals the step's result body and its action link.
    |> click("[data-prepare-step='source'] [data-prepare-head]")
    |> assert_has("[data-prepare-step='source'][data-open]")
    |> assert_has("[data-prepare-step='source'] a", text: "Manage on edit page")
  end

  # Stays a browser test: theme persistence is localStorage + the inline
  # theme-migration script in the root layout - no server involvement.
  test "theme persists across page navigation", %{conn: conn} do
    conn
    |> visit("/login")
    # Set theme via JS. Use a current slug ("deep-space") - retired slugs like
    # "nebula" get rewritten by the theme-migration script on load.
    |> evaluate("""
      document.documentElement.setAttribute('data-theme', 'deep-space');
      localStorage.setItem('theme', 'deep-space');
    """)
    # Navigate again: the inline script must re-apply the saved theme.
    |> visit("/login")
    |> evaluate(
      "() => document.documentElement.getAttribute('data-theme')",
      [is_function: true],
      fn theme -> assert theme == "deep-space" end
    )
  end
end
