defmodule RuleMavenWeb.GameLiveToolPanelTest do
  @moduledoc """
  The table-tools panel is a server-side state machine: `@tool_states` maps a
  tool id to :expanded | :minimized, with at most one :expanded. Opening a
  second tool demotes the first to the dock; each tool's own state (quiz score,
  etc.) survives close because it lives in separate assigns.
  """
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp user do
    {:ok, u} =
      RuleMaven.Users.create_user(%{
        username: "toolpanel_user",
        email: "toolpanel_user@test.com",
        password: "password1234"
      })

    u
  end

  defp seed_tools(game) do
    RuleMaven.Settings.put(
      "turn_flow_#{game.id}",
      Jason.encode!([%{"name" => "Roll", "note" => "", "actions" => []}])
    )

    RuleMaven.Settings.put(
      "quiz_#{game.id}",
      Jason.encode!([
        %{"q" => "Q1?", "choices" => ["a", "b"], "answer" => 0, "why" => "because"}
      ])
    )
  end

  defp open_view(conn, connect_params \\ %{}) do
    u = user()
    game = published_game_fixture(%{name: "Tool Panel Game"})
    seed_tools(game)

    conn =
      conn
      |> login(u)
      |> Phoenix.LiveViewTest.put_connect_params(connect_params)

    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")
    view
  end

  # Render order is paint order: the tool appearing last in the markup is the
  # window on top.
  defp stack(html) do
    Regex.scan(~r/data-tool-panel="([a-z_]+)"/, html) |> Enum.map(fn [_, id] -> id end)
  end

  test "desktop stacks windows, newest on top", %{conn: conn} do
    view = open_view(conn)

    render_click(view, "open_tool", %{"tool" => "turn"})
    html = render_click(view, "open_tool", %{"tool" => "quiz"})

    # Both stay expanded; neither is demoted to the tray.
    assert stack(html) == ["turn", "quiz"]
    refute html =~ ~s(data-dock-pill=)
  end

  test "clicking a window brings it to the front of the stack", %{conn: conn} do
    view = open_view(conn)

    render_click(view, "open_tool", %{"tool" => "turn"})
    render_click(view, "open_tool", %{"tool" => "quiz"})
    html = render_click(view, "focus_tool", %{"tool" => "turn"})

    assert stack(html) == ["quiz", "turn"]
  end

  test "focusing a minimized or unknown tool does not change the stack", %{conn: conn} do
    view = open_view(conn)

    render_click(view, "open_tool", %{"tool" => "turn"})
    render_click(view, "open_tool", %{"tool" => "quiz"})
    render_click(view, "minimize_tool", %{"tool" => "turn"})

    html = render_click(view, "focus_tool", %{"tool" => "turn"})
    assert stack(html) == ["quiz"]

    html = render_click(view, "focus_tool", %{"tool" => "bogus"})
    assert stack(html) == ["quiz"]
  end

  test "a closed window leaves the stack", %{conn: conn} do
    view = open_view(conn)

    render_click(view, "open_tool", %{"tool" => "turn"})
    render_click(view, "open_tool", %{"tool" => "quiz"})
    html = render_click(view, "close_tool", %{"tool" => "quiz"})

    assert stack(html) == ["turn"]
  end

  test "a phone shows one sheet at a time: opening a second demotes the first", %{conn: conn} do
    view = open_view(conn, %{"coarse_pointer" => true})

    render_click(view, "open_tool", %{"tool" => "turn"})
    html = render_click(view, "open_tool", %{"tool" => "quiz"})

    assert stack(html) == ["quiz"]
    assert html =~ ~s(data-dock-pill="turn")
  end

  test "tray renders only while a tool is minimized", %{conn: conn} do
    view = open_view(conn)

    html = render_click(view, "open_tool", %{"tool" => "turn"})
    refute html =~ ~s(data-tool-dock)

    html = render_click(view, "minimize_tool", %{"tool" => "turn"})
    assert html =~ ~s(data-tool-dock)
    assert html =~ ~s(id="tool-tray")
  end

  test "a tray pill closes its tool without restoring it", %{conn: conn} do
    view = open_view(conn)

    render_click(view, "open_tool", %{"tool" => "turn"})
    render_click(view, "minimize_tool", %{"tool" => "turn"})
    html = render_click(view, "close_tool", %{"tool" => "turn"})

    refute html =~ ~s(data-dock-pill="turn")
    refute html =~ ~s(data-tool-panel="turn")
  end

  test "quiz score survives close and re-open", %{conn: conn} do
    view = open_view(conn)

    render_click(view, "open_tool", %{"tool" => "quiz"})
    render_click(view, "quiz_answer", %{"choice" => "0"})
    render_click(view, "close_tool", %{"tool" => "quiz"})
    html = render_click(view, "open_tool", %{"tool" => "quiz"})

    # asked count is preserved (1), not reset to 0
    assert html =~ "Score 1/1"
  end

  test "invalid tool id is ignored", %{conn: conn} do
    view = open_view(conn)
    html = render_click(view, "open_tool", %{"tool" => "bogus"})
    refute html =~ ~s(data-tool-panel="bogus")
  end
end
