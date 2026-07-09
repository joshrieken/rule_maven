defmodule RuleMavenWeb.GameLiveToolPersistenceTest do
  @moduledoc """
  Open tool windows must follow the user around: across thread patches within
  the game page, and across full navigations to other game screens (community)
  via the server-side RuleMaven.TableSession snapshot.
  """
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp user do
    {:ok, u} =
      RuleMaven.Users.create_user(%{
        username: "toolpersist_user",
        email: "toolpersist_user@test.com",
        password: "password1234"
      })

    u
  end

  defp setup_game(conn) do
    u = user()
    game = published_game_fixture(%{name: "Persistence Game"})

    RuleMaven.Settings.put(
      "turn_flow_#{game.id}",
      Jason.encode!([%{"name" => "Roll", "note" => "", "actions" => []}])
    )

    {login(conn, u), u, game}
  end

  defp token(game), do: RuleMaven.Hashid.encode(game.id)

  test "windows survive a patch to the overview", %{conn: conn} do
    {conn, user, game} = setup_game(conn)
    {:ok, view, _html} = live(conn, ~p"/games/#{token(game)}")

    render_click(view, "open_tool", %{"tool" => "timer"})
    assert has_element?(view, "#tool-panel-timer")

    # patch to the overview — same LiveView, handle_params re-runs
    html = render_patch(view, ~p"/games/#{token(game)}?start=1")
    assert html =~ ~s(id="tool-panel-timer")

    assert %{tool_states: %{timer: :expanded}} = RuleMaven.TableSession.get(user.id, game.id)
  end

  test "windows survive a full remount of the game page", %{conn: conn} do
    {conn, _user, game} = setup_game(conn)
    {:ok, view, _html} = live(conn, ~p"/games/#{token(game)}")

    render_click(view, "open_tool", %{"tool" => "turn"})
    render_click(view, "turn_next", %{})
    render_click(view, "open_tool", %{"tool" => "timer"})
    render_click(view, "minimize_tool", %{"tool" => "turn"})

    {:ok, view2, html2} = live(conn, ~p"/games/#{token(game)}")
    assert html2 =~ ~s(id="tool-panel-timer")
    assert html2 =~ ~s(data-dock-pill="turn")
    assert has_element?(view2, "#tool-tray")
  end

  test "windows survive navigating from game page to community and back", %{conn: conn} do
    {conn, _user, game} = setup_game(conn)
    {:ok, view, _html} = live(conn, ~p"/games/#{token(game)}")

    render_click(view, "open_tool", %{"tool" => "timer"})
    render_click(view, "open_tool", %{"tool" => "turn"})
    render_click(view, "turn_next", %{})

    # Different LiveView: state must come from TableSession, not the socket.
    {:ok, cview, chtml} = live(conn, ~p"/games/#{token(game)}/community")
    assert chtml =~ ~s(id="tool-panel-timer")
    assert chtml =~ ~s(id="tool-panel-turn")

    # Mutations on community carry back to the game page.
    render_click(cview, "minimize_tool", %{"tool" => "timer"})

    {:ok, _view2, html2} = live(conn, ~p"/games/#{token(game)}")
    assert html2 =~ ~s(id="tool-panel-turn")
    assert html2 =~ ~s(data-dock-pill="timer")
  end
end
