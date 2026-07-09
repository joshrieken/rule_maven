defmodule RuleMavenWeb.GameTableContextTest do
  @moduledoc """
  Task 2: the always-visible table-context strip — what this user is playing
  with (selected expansions + house-rule count) — renders under the game
  title on every game screen and taps into the `:expansions` / `:house_rules`
  tools.
  """
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{
            username: "#{prefix}_user",
            email: "#{prefix}_user@test.com",
            password: "password1234"
          },
          attrs
        )
      )

    user
  end

  setup %{conn: conn} do
    user = create_user("tablectx")
    base = published_game_fixture(%{name: "Wingspan", bgg_id: 9101})
    %{conn: login(conn, user), user: user, base: base}
  end

  # The game must HAVE an expansion for the 🎲 half to render at all; the user
  # simply hasn't selected it. A game with no expansions hides the half entirely
  # — see the last test in this file.
  test "an unselected expansion shows the muted base label",
       %{conn: conn, user: user, base: base} do
    exp = published_game_fixture(%{name: "Oceania", bgg_id: 9102})
    RuleMaven.Games.link_expansion(exp.id, base.id)

    RuleMaven.Games.put_expansion_selection(user.id, base.id, [])

    {:ok, _view, html} = live(conn, ~p"/games/#{base}")
    assert html =~ "Base game"
  end

  test "no house rules shows an Add affordance", %{conn: conn, base: base} do
    {:ok, _view, html} = live(conn, ~p"/games/#{base}")
    assert html =~ ~s|data-testid="table-context-house-rules"|
    assert html =~ "Add"
  end

  test "selected expansions are named, extras collapse to +N",
       %{conn: conn, user: user, base: base} do
    for {n, bgg_id} <- [{"Oceania", 9103}, {"European", 9104}, {"Asia", 9105}] do
      exp = published_game_fixture(%{name: n, bgg_id: bgg_id})
      RuleMaven.Games.link_expansion(exp.id, base.id)
    end

    ids = base |> RuleMaven.Games.expansions_with_documents() |> Enum.map(& &1.id)
    RuleMaven.Games.put_expansion_selection(user.id, base.id, ids)

    {:ok, _view, html} = live(conn, ~p"/games/#{base}")
    assert html =~ "Oceania"
    assert html =~ "+2"
  end

  test "a game with no expansions hides the expansions half",
       %{conn: conn, base: base} do
    {:ok, _view, html} = live(conn, ~p"/games/#{base}")
    refute html =~ ~s|data-testid="table-context-expansions"|
  end

  # Only proves the attribute is rendered. Whether the element is *visible* —
  # the property that decides if the tour step runs or is silently skipped —
  # cannot be checked from markup. That is verified in a browser; see
  # docs/superpowers/plans/2026-07-09-table-context-ui.md, Task 4.
  test "the expansions tour step's selector is present in the markup",
       %{conn: conn, base: base} do
    exp = published_game_fixture(%{name: "Oceania", bgg_id: 9106})
    RuleMaven.Games.link_expansion(exp.id, base.id)

    {:ok, _view, html} = live(conn, ~p"/games/#{base}")
    assert html =~ ~s|data-tour="expansions"|
  end

  # The Edit screen's `included_expansions` assign is a different concept
  # (the admin's expansion-link editor state, not "what this user plays
  # with"), so the "what's at my table" strip is meaningless there — it must
  # not render at all, regardless of what the admin has linked/selected.
  test "the strip does not render on the admin Edit screen",
       %{conn: conn, user: user, base: base} do
    {:ok, admin} =
      RuleMaven.Users.create_user(%{
        username: "tablectx_admin",
        email: "tablectx_admin@test.com",
        password: "password1234",
        role: "admin"
      })

    exp = published_game_fixture(%{name: "Oceania", bgg_id: 9107})
    RuleMaven.Games.link_expansion(exp.id, base.id)
    RuleMaven.Games.put_expansion_selection(user.id, base.id, [])

    conn = login(conn, admin)
    {:ok, _view, html} = live(conn, ~p"/games/#{base}/edit")

    refute html =~ ~s|data-testid="table-context-expansions"|
    refute html =~ ~s|data-testid="table-context-house-rules"|
  end

  test "the strip still renders on show and community", %{conn: conn, base: base} do
    {:ok, _view, show_html} = live(conn, ~p"/games/#{base}")
    assert show_html =~ ~s|data-testid="table-context-house-rules"|

    {:ok, _view, community_html} = live(conn, ~p"/games/#{base}/community")
    assert community_html =~ ~s|data-testid="table-context-house-rules"|
  end
end
