defmodule RuleMavenWeb.LiveNavigationTest do
  @moduledoc """
  Pages move live (PLATFORM.md §6): the links people use to move between
  LiveView pages are `navigate` links, and every signed-in page shares the one
  `:app` live_session, so a hop swaps the page over the open socket instead of
  reloading it. Controller pages (Help, What's new, sign-in/out) and files stay
  plain links.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp super_admin do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "live_nav_admin",
        email: "live_nav_admin@test.com",
        password: "password1234",
        role: "admin"
      })

    {:ok, user} = RuleMaven.Users.set_super_admin(user, true)
    user
  end

  # A navigate link renders as <a href=… data-phx-link="redirect" …>.
  defp live_link?(html, path), do: html =~ ~s(href="#{path}" data-phx-link="redirect")

  test "a page's back link moves live, without a reload", %{conn: conn} do
    {:ok, view, _html} = live(login(conn, super_admin()), ~p"/admin/health")

    assert {:error, {:live_redirect, %{kind: :push, to: "/admin"}}} =
             view |> element("a.back-link") |> render_click()
  end

  test "the header and drawer links to LiveView pages are navigate links", %{conn: conn} do
    {:ok, _view, html} = live(login(conn, super_admin()), ~p"/admin/health")

    for path <- ~w(/ /admin /admin/users /admin/questions /admin/db /settings /standing /groups) do
      assert live_link?(html, path), "#{path} should be a navigate link"
    end

    # Controller pages, the Oban dashboard (its own live_session) and sign-out
    # stay full page loads.
    for path <- ~w(/help /changelog /logout /oban) do
      assert html =~ ~s(href="#{path}"), "#{path} should be linked"
      refute live_link?(html, path), "#{path} should stay a plain link"
    end
  end

  test "user and admin pages share one live_session: hops between them don't reload",
       %{conn: conn} do
    conn = login(conn, super_admin())
    {:ok, view, _html} = live(conn, ~p"/admin/health")

    # live_redirect stays on the socket; across a live_session boundary it
    # would come back as {:error, {:redirect, _}} (a full page load).
    assert {:ok, view, _html} = live_redirect(view, to: ~p"/")
    assert {:ok, view, _html} = live_redirect(view, to: ~p"/settings")
    assert {:ok, view, _html} = live_redirect(view, to: ~p"/admin/users")
    assert {:ok, _view, _html} = live_redirect(view, to: ~p"/groups")
  end

  test "DB Admin's table tabs patch the page in place", %{conn: conn} do
    {:ok, view, _html} = live(login(conn, super_admin()), ~p"/admin/db")

    view |> element(~s(a[href="/admin/db?table=games"])) |> render_click()
    assert_patch(view, ~p"/admin/db?table=games")
  end
end
