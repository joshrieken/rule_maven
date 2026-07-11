defmodule RuleMavenWeb.GameLive.ToolFlagGateTest do
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMavenWeb.GameLive.ToolRegistry

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp user(role) do
    {:ok, u} =
      RuleMaven.Users.create_user(%{
        username: "u#{System.unique_integer([:positive])}",
        email: "u#{System.unique_integer([:positive])}@test.com",
        password: "password1234",
        role: role
      })

    u
  end

  setup do
    {:ok, game: game_fixture(%{name: "Flag Game", bgg_id: System.unique_integer([:positive])})}
  end

  test "a flagged-off tool is hidden from the Learn menu", %{conn: conn, game: game} do
    {:ok, _} = RuleMaven.Flags.disable(:tool_quiz)
    u = user("user")

    {:ok, _view, html} = conn |> login(u) |> live(~p"/games/#{game}")

    refute html =~ "Rules quiz"
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "visible?/2 is true for an admin even when the boolean gate is off" do
    {:ok, _} = RuleMaven.Flags.disable(:tool_quiz)
    {:ok, _} = RuleMaven.Flags.enable_for_admins(:tool_quiz)

    refute ToolRegistry.visible?(:quiz, user("user"))
    assert ToolRegistry.visible?(:quiz, user("admin"))
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "opening a flagged-off tool via forged event is a no-op", %{conn: conn, game: game} do
    {:ok, _} = RuleMaven.Flags.disable(:tool_quiz)
    u = user("user")

    {:ok, view, _html} = conn |> login(u) |> live(~p"/games/#{game}")

    render_click(view, "open_tool", %{"tool" => "quiz"})
    refute render(view) =~ ~s(data-tool-panel="quiz")
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "a flagged-off Expansions pill is absent from the table-context strip even with a linked expansion",
       %{conn: conn} do
    base =
      published_game_fixture(%{name: "Flag Base", bgg_id: System.unique_integer([:positive])})

    exp =
      published_game_fixture(%{
        name: "Flag Expansion",
        bgg_id: System.unique_integer([:positive])
      })

    RuleMaven.Games.link_expansion(exp.id, base.id)

    {:ok, _} = RuleMaven.Flags.disable(:tool_expansions)
    u = user("user")

    {:ok, _view, html} = conn |> login(u) |> live(~p"/games/#{base}")

    refute html =~ ~s(data-testid="table-context-expansions")
    refute html =~ ~s(phx-value-tool="expansions")
  after
    FunWithFlags.clear(:tool_expansions)
  end

  test "a flagged-off House-rules pill is absent from the table-context strip", %{
    conn: conn,
    game: game
  } do
    {:ok, _} = RuleMaven.Flags.disable(:tool_house_rules)
    u = user("user")

    {:ok, _view, html} = conn |> login(u) |> live(~p"/games/#{game}")

    refute html =~ ~s(data-testid="table-context-house-rules")
    refute html =~ ~s(phx-value-tool="house_rules")
  after
    FunWithFlags.clear(:tool_house_rules)
  end

  test "the crew Feed pill is hidden when tool_group_feed is off", %{conn: conn} do
    # ToolHost silently drops an `open_tool` for a disabled tool, so an ungated
    # pill would render as a button that simply does nothing.
    u = user("user")
    grp = RuleMaven.GroupsFixtures.group_fixture(u)
    conn = login(conn, u)

    # The shared `game` here is unpublished, which renders the "not ready" page
    # and no header at all — this test needs the real game screen.
    game = published_game_fixture(%{bgg_id: System.unique_integer([:positive])})

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    lv |> element("[phx-value-group='#{Phoenix.Param.to_param(grp)}']") |> render_click()
    assert render(lv) =~ "group-feed-toggle"

    {:ok, _} = RuleMaven.Flags.disable(:tool_group_feed)

    {:ok, lv2, _html} = live(conn, ~p"/games/#{game}")
    lv2 |> element("[phx-value-group='#{Phoenix.Param.to_param(grp)}']") |> render_click()
    refute render(lv2) =~ "group-feed-toggle"
  end
end
