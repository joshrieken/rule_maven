defmodule RuleMavenWeb.GameExpansionsToolTest do
  @moduledoc """
  Task 1: the expansion picker becomes a `:expansions` tool, reachable from
  every game screen via ToolHost — not just buried in the Q&A composer.
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
    user = create_user("expansions")
    # published_game_fixture flags `playable: true` directly on the row (the
    # changeset doesn't cast :playable) so the base game clears the
    # `%{playable: false, is_admin: false}` gate and renders the real page.
    base = published_game_fixture(%{name: "Wingspan", bgg_id: 9001})
    # expansions_with_documents/1 (what the tool lists) requires the
    # expansion to have its own published rulebook — no docs, nothing to
    # answer from, so it isn't a real toggle choice.
    exp = published_game_fixture(%{name: "Oceania", bgg_id: 9002})
    # link_expansion/2 takes IDs, expansion first. games.ex:169
    RuleMaven.Games.link_expansion(exp.id, base.id)
    %{conn: login(conn, user), user: user, base: base, exp: exp}
  end

  # Task 2 added a second way to open the same tool — the always-visible
  # table-context strip (`data-testid="table-context-expansions"`) — beside
  # the pre-existing Play-menu item, so the plain `open_tool`/`expansions`
  # selector now matches two elements. Scope to the Play menu's item here;
  # the strip's own open path is covered by game_table_context_test.exs.
  test "toggling an expansion from the tool persists the selection",
       %{conn: conn, user: user, base: base, exp: exp} do
    {:ok, view, _html} = live(conn, ~p"/games/#{base}")

    view
    |> element(~s|.card-menu__item[phx-click="open_tool"][phx-value-tool="expansions"]|)
    |> render_click()

    view |> element(~s|[phx-click="toggle_expansion"][phx-value-id="#{exp.id}"]|) |> render_click()

    assert RuleMaven.Games.get_expansion_selection(user.id, base.id) == [exp.id]
  end

  test "toggling from the community screen does not crash",
       %{conn: conn, user: user, base: base, exp: exp} do
    {:ok, view, _html} = live(conn, ~p"/games/#{base}/community")

    view
    |> element(~s|.card-menu__item[phx-click="open_tool"][phx-value-tool="expansions"]|)
    |> render_click()

    view |> element(~s|[phx-click="toggle_expansion"][phx-value-id="#{exp.id}"]|) |> render_click()

    assert RuleMaven.Games.get_expansion_selection(user.id, base.id) == [exp.id]
  end
end
