defmodule RuleMavenWeb.GameTableContextTest do
  @moduledoc """
  The table-context strip — what this user is playing with (selected expansions
  + house-rule count) — and the screens it belongs on.

  It is NOT on every game screen. Each half was pulled from the screen that
  already owned its destination elsewhere:

    * `:show` (Q&A) renders neither half — its 🧰 Tools menu carries both
      Expansions and House rules, and the header needs the width for the crew
      selector.
    * `:community` renders the expansions half only — house rules live in that
      page's Tools menu (Learn section).
    * `:prepare` / `:review` render both halves. Both are admin-only views.
    * `:edit` renders neither: `included_expansions` there is the expansion-link
      editor's state, not "what this user plays with".
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

  # The game must HAVE an expansion for the 📦 half to render at all; the user
  # simply hasn't selected it. A game with no expansions hides the half entirely
  # — see "a game with no expansions hides the expansions half".
  test "an unselected expansion shows the muted base label",
       %{conn: conn, user: user, base: base} do
    exp = published_game_fixture(%{name: "Oceania", bgg_id: 9102})
    RuleMaven.Games.link_expansion(exp.id, base.id)

    RuleMaven.Games.put_expansion_selection(user.id, base.id, [])

    {:ok, _view, html} = live(conn, ~p"/games/#{base}/community")
    assert html =~ "Base game"
  end

  # Prepare is the only non-admin-free screen carrying the house-rules half, so
  # this one needs an admin to get past `UserLiveAuth`'s @admin_views gate.
  test "no house rules shows an Add affordance", %{conn: conn, base: base} do
    admin = create_user("tablectx_admin", %{role: "admin"})

    conn = login(conn, admin)
    {:ok, _view, html} = live(conn, ~p"/games/#{base}/prepare")

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

    {:ok, _view, html} = live(conn, ~p"/games/#{base}/community")
    assert html =~ "Oceania"
    assert html =~ "+2"
  end

  test "a game with no expansions hides the expansions half",
       %{conn: conn, base: base} do
    {:ok, _view, html} = live(conn, ~p"/games/#{base}/community")
    refute html =~ ~s|data-testid="table-context-expansions"|
  end

  # The strip renders both labels and CSS picks one: below 640px the long
  # expansion name is hidden and a bare count takes its place, because the
  # header's free width there (~149px) cannot hold the name (~245px) without
  # the strip claiming a second 40px row.
  test "the strip carries both a full label and a compact count",
       %{conn: conn, user: user, base: base} do
    for n <- ["Oceania", "European"] do
      exp = published_game_fixture(%{name: n, bgg_id: 9200 + String.length(n)})
      RuleMaven.Games.link_expansion(exp.id, base.id)
    end

    ids = base |> RuleMaven.Games.expansions_with_documents() |> Enum.map(& &1.id)
    RuleMaven.Games.put_expansion_selection(user.id, base.id, ids)

    {:ok, _view, html} = live(conn, ~p"/games/#{base}/community")

    assert html =~ ~s|class="tc-label"|
    assert html =~ ~s|class="tc-label-compact"|
    # The compact label is the selected count, not the name.
    assert html =~ ~s|<span class="tc-label-compact">2</span>|
  end

  # Only proves the attribute is rendered. Whether the element is *visible* —
  # the property that decides if the tour step runs or is silently skipped —
  # cannot be checked from markup. That is verified in a browser; see
  # docs/superpowers/plans/2026-07-09-table-context-ui.md, Task 4.
  test "the expansions tour step's selector is present in the markup",
       %{conn: conn, base: base} do
    exp = published_game_fixture(%{name: "Oceania", bgg_id: 9106})
    RuleMaven.Games.link_expansion(exp.id, base.id)

    {:ok, _view, html} = live(conn, ~p"/games/#{base}/community")
    assert html =~ ~s|data-tour="expansions"|
  end

  # The Edit screen's `included_expansions` assign is a different concept
  # (the admin's expansion-link editor state, not "what this user plays
  # with"), so the "what's at my table" strip is meaningless there — it must
  # not render at all, regardless of what the admin has linked/selected.
  test "the strip does not render on the admin Edit screen",
       %{conn: conn, user: user, base: base} do
    admin = create_user("tablectx_edit_admin", %{role: "admin"})

    exp = published_game_fixture(%{name: "Oceania", bgg_id: 9107})
    RuleMaven.Games.link_expansion(exp.id, base.id)
    RuleMaven.Games.put_expansion_selection(user.id, base.id, [])

    conn = login(conn, admin)
    {:ok, _view, html} = live(conn, ~p"/games/#{base}/edit")

    refute html =~ ~s|data-testid="table-context-expansions"|
    refute html =~ ~s|data-testid="table-context-house-rules"|
  end

  # Both halves were deliberately taken off the Q&A screen: its 🧰 Tools menu
  # already owns both destinations (Play → Expansions, Learn → House rules) and
  # the header needs the reclaimed width for the crew selector. Community keeps
  # the expansions half — it is the one bit of table context an answer's
  # provenance depends on — but drops the house-rules pill, which its Tools menu
  # also carries and which read as chrome noise there.
  test "the strip is absent on Q&A; Community keeps expansions but not house rules",
       %{conn: conn, user: user, base: base} do
    exp = published_game_fixture(%{name: "Oceania", bgg_id: 9108})
    RuleMaven.Games.link_expansion(exp.id, base.id)
    RuleMaven.Games.put_expansion_selection(user.id, base.id, [exp.id])

    {:ok, _view, show_html} = live(conn, ~p"/games/#{base}")
    refute show_html =~ ~s|data-testid="table-context-expansions"|
    refute show_html =~ ~s|data-testid="table-context-house-rules"|

    {:ok, _view, community_html} = live(conn, ~p"/games/#{base}/community")
    assert community_html =~ ~s|data-testid="table-context-expansions"|
    refute community_html =~ ~s|data-testid="table-context-house-rules"|
  end
end
