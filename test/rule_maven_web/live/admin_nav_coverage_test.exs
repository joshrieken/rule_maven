defmodule RuleMavenWeb.AdminNavCoverageTest do
  @moduledoc """
  Every `/admin/*` page must be reachable from the admin menus.

  `/admin/flags` shipped linked only from the dashboard card grid, so it was
  invisible from the header dropdown and the mobile drawer — you had to know the
  URL. Rather than fix that one link and wait for the next orphan, this derives
  the admin routes from the router and asserts each one is linked from the
  chrome, so a new admin page cannot be added without being navigable.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp admin do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "nav_admin",
        email: "nav_admin@test.com",
        password: "password1234",
        role: "admin"
      })

    user
  end

  # Every distinct /admin/* path the router serves.
  defp admin_paths do
    RuleMavenWeb.Router
    |> Phoenix.Router.routes()
    |> Enum.map(& &1.path)
    |> Enum.filter(&String.starts_with?(&1, "/admin"))
    # Skip parameterised routes — a menu can't link to /admin/thing/:id.
    |> Enum.reject(&String.contains?(&1, ":"))
    |> Enum.uniq()
  end

  # Deliberately NOT /admin: the dashboard renders a card grid that links every
  # admin page, so asserting against it would pass even with the menus empty —
  # which is precisely the bug this file exists to catch (/admin/flags was
  # reachable only from that grid). Any other admin page renders the same root
  # layout, so every /admin/* href in it comes from the menus.
  defp chrome_html(conn) do
    {:ok, _lv, html} = live(login(conn, admin()), ~p"/admin/health")
    html
  end

  test "every admin page is linked from the admin menus", %{conn: conn} do
    html = chrome_html(conn)

    missing =
      Enum.reject(admin_paths(), fn path ->
        # Anchored on the closing quote, so /admin doesn't match /admin/flags
        # and mask a genuinely missing link.
        String.contains?(html, ~s|href="#{path}"|)
      end)

    assert missing == [],
           "these admin pages are not linked from any admin menu: #{inspect(missing)}"
  end

  test "the feature flags console is in the header dropdown and the mobile drawer", %{conn: conn} do
    # Both menus live in the root layout and are both rendered (the drawer is
    # CSS-hidden on desktop, not omitted), so the link must appear twice.
    occurrences =
      chrome_html(conn)
      |> String.split(~s|href="/admin/flags"|)
      |> length()
      |> Kernel.-(1)

    assert occurrences >= 2,
           "expected /admin/flags in both the header dropdown and the mobile drawer, found #{occurrences}"
  end
end
