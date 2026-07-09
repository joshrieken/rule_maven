defmodule RuleMavenWeb.LiveSessionNavBoundaryTest do
  @moduledoc """
  Pages that `navigate` to each other must share a `live_session`.

  LiveView can only keep the existing socket when both routes belong to the same
  live_session; across a boundary it tears the socket down and does a full HTTP
  page load. Prepare's back arrow (`~p"/"`) and title link (`~p"/games/:id"`)
  used to cross exactly that boundary — Prepare was `:admin`, the games list and
  overview were `:default` — so leaving Prepare blanked the page and re-fetched
  the list.

  `Phoenix.LiveViewTest` does *not* simulate the boundary (it live-redirects
  happily), so the only thing that catches a regression here is the router's own
  live_session metadata.
  """

  use ExUnit.Case, async: true

  alias RuleMavenWeb.Router

  defp live_session_name(path) do
    {_view, _action, _opts, extra} =
      Router
      |> Phoenix.Router.route_info("GET", path, "example.com")
      |> Map.fetch!(:phoenix_live_view)

    Map.fetch!(extra, :name)
  end

  # Every pair here is a `navigate` that exists in the UI today.
  @navigable_pairs [
    {"prepare -> games list", "/games/abc/prepare", "/"},
    {"prepare -> game overview", "/games/abc/prepare", "/games/abc"},
    {"review -> games list", "/games/abc/review", "/"},
    {"game overview -> edit", "/games/abc", "/games/abc/edit"},
    {"game overview -> review", "/games/abc", "/games/abc/review"},
    {"games list -> new game", "/", "/games/new"}
  ]

  for {label, from, to} <- @navigable_pairs do
    test "#{label} stays inside one live_session" do
      assert live_session_name(unquote(from)) == live_session_name(unquote(to)),
             """
             #{unquote(from)} and #{unquote(to)} are in different live_sessions, so \
             navigating between them forces a full page reload instead of a connected \
             LiveView transition.
             """
    end
  end

  test "the admin gate still runs on an admin-only route" do
    {_view, _action, _opts, extra} =
      Router
      |> Phoenix.Router.route_info("GET", "/admin/db", "example.com")
      |> Map.fetch!(:phoenix_live_view)

    on_mount_ids = Enum.map(extra.extra.on_mount, & &1.id)
    assert {RuleMavenWeb.UserLiveAuth, :app} in on_mount_ids
  end

  test "every admin LiveView is recognised by the gate, and no user-facing one is" do
    for view <- [
          RuleMavenWeb.GameLive.Prepare,
          RuleMavenWeb.GameLive.Review,
          RuleMavenWeb.GameLive.Form,
          RuleMavenWeb.AdminLive.Db,
          RuleMavenWeb.AdminLive.Users
        ] do
      assert RuleMavenWeb.UserLiveAuth.admin_view?(view), "#{inspect(view)} lost its admin gate"
    end

    for view <- [
          RuleMavenWeb.GameLive.Index,
          RuleMavenWeb.GameLive.Show,
          RuleMavenWeb.GameLive.Community,
          RuleMavenWeb.SettingsLive
        ] do
      refute RuleMavenWeb.UserLiveAuth.admin_view?(view),
             "#{inspect(view)} became admin-only"
    end
  end

  test "no /admin route escapes the gate" do
    admin_paths =
      Router.__routes__()
      |> Enum.filter(&String.starts_with?(&1.path, "/admin"))
      |> Enum.filter(&match?({_, _, _, _}, &1.metadata[:phoenix_live_view]))

    assert admin_paths != []

    for route <- admin_paths do
      {view, _action, _opts, _extra} = route.metadata.phoenix_live_view

      assert RuleMavenWeb.UserLiveAuth.admin_view?(view),
             "#{route.path} (#{inspect(view)}) mounts without the admin check"
    end
  end
end
