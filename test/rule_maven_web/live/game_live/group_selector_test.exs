defmodule RuleMavenWeb.GameLive.GroupSelectorTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures
  import RuleMaven.GroupsFixtures

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

  test "selecting a group sets active_group_id and it sticks", %{conn: conn} do
    user = create_user("sel")
    game = published_game_fixture(%{bgg_id: 101})
    grp = group_fixture(user)
    conn = login(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    token = Phoenix.Param.to_param(grp)

    lv |> element("[phx-value-group='#{token}']") |> render_click()
    assert RuleMaven.TableSession.get(user.id, game.id)[:active_group_id] == grp.id

    # remount: stickiness restores it
    {:ok, lv2, _html} = live(conn, ~p"/games/#{game}")
    assert lv2.module == RuleMavenWeb.GameLive.Show
    assert render(lv2) =~ grp.name
  end

  test "selecting 'Just me' clears it back to nil", %{conn: conn} do
    user = create_user("clr")
    game = published_game_fixture(%{bgg_id: 102})
    grp = group_fixture(user)
    conn = login(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    token = Phoenix.Param.to_param(grp)
    lv |> element("[phx-value-group='#{token}']") |> render_click()
    assert RuleMaven.TableSession.get(user.id, game.id)[:active_group_id] == grp.id

    lv |> element("[phx-value-group='']") |> render_click()
    assert RuleMaven.TableSession.get(user.id, game.id)[:active_group_id] == nil
  end

  test "a forged/garbage token does not set an active group", %{conn: conn} do
    user = create_user("forge")
    game = published_game_fixture(%{bgg_id: 103})
    _grp = group_fixture(user)
    conn = login(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")

    render_click(lv, "set_active_group", %{"group" => "totally-garbage-token"})

    assert RuleMaven.TableSession.get(user.id, game.id)[:active_group_id] == nil
  end

  test "a real group the user is not a member of does not set an active group", %{conn: conn} do
    owner = create_user("owner")
    other = create_user("outsider")
    game = published_game_fixture(%{bgg_id: 104})
    grp = group_fixture(owner)
    conn = login(conn, other)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    token = Phoenix.Param.to_param(grp)

    render_click(lv, "set_active_group", %{"group" => token})

    assert RuleMaven.TableSession.get(other.id, game.id)[:active_group_id] == nil
  end

  test "a user with no groups sees no selector", %{conn: conn} do
    user = create_user("nogrp")
    game = published_game_fixture(%{bgg_id: 105})
    conn = login(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/games/#{game}")

    refute html =~ "set_active_group"
  end

  test "stickiness drops if the user is no longer a member of the stashed group", %{conn: conn} do
    owner = create_user("owner2")
    member = create_user("evicted")
    game = published_game_fixture(%{bgg_id: 106})
    grp = group_fixture(owner)
    {:ok, _} = RuleMaven.Groups.join_by_code(member, grp.invite_code)
    conn = login(conn, member)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    token = Phoenix.Param.to_param(grp)
    lv |> element("[phx-value-group='#{token}']") |> render_click()
    assert RuleMaven.TableSession.get(member.id, game.id)[:active_group_id] == grp.id

    # user is no longer a member (removed)
    RuleMaven.Groups.remove_member(owner, grp, member.id)

    {:ok, lv2, _html} = live(conn, ~p"/games/#{game}")
    refute render(lv2) =~ grp.name
  end

  test "the active crew survives a tool event (opening the Feed panel)", %{conn: conn} do
    # ToolHost persists Map.take(assigns, @session_keys) on EVERY tool event, and
    # :active_group_id isn't one of its keys — under the old replace-semantics
    # TableSession.put/3 that wiped the crew, so opening the Feed panel itself
    # un-stuck the crew and the next ask went out private.
    user = create_user("sticky")
    game = published_game_fixture(%{bgg_id: 107})
    grp = group_fixture(user)
    conn = login(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    token = Phoenix.Param.to_param(grp)
    lv |> element("[phx-value-group='#{token}']") |> render_click()

    lv |> element("[data-testid='group-feed-toggle']") |> render_click()

    assert RuleMaven.TableSession.get(user.id, game.id)[:active_group_id] == grp.id

    {:ok, lv2, _html} = live(conn, ~p"/games/#{game}")
    assert render(lv2) =~ grp.name
  end
end
