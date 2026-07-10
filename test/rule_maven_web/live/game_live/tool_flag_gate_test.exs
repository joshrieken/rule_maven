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
end
