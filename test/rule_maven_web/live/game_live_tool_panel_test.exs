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

  defp open_view(conn) do
    u = user()
    game = published_game_fixture(%{name: "Tool Panel Game"})
    seed_tools(game)
    conn = login(conn, u)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")
    view
  end

  test "opening a second tool demotes the first to minimized", %{conn: conn} do
    view = open_view(conn)

    render_click(view, "open_tool", %{"tool" => "turn"})
    render_click(view, "open_tool", %{"tool" => "quiz"})

    # Both present; exactly one expanded panel, one dock pill.
    html = render(view)
    assert html =~ ~s(data-tool-state="expanded")
    assert html =~ ~s(data-tool-panel="quiz")
    # turn is now a dock pill
    assert html =~ ~s(data-dock-pill="turn")
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
