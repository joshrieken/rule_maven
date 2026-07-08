defmodule RuleMavenWeb.GameLiveTurnWizardTest do
  @moduledoc """
  The "What can I do now?" turn wizard opens as a floating tool panel (launched
  from the Play menu via the `open_tool` event). Pins that the wizard renders its
  first phase once opened, and that clicking Next advances the phase while the
  panel stays expanded.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp setup_user(prefix) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "#{prefix}_user",
        email: "#{prefix}_user@test.com",
        password: "password1234"
      })

    user
  end

  defp seed_turn_flow(game) do
    flow = [
      %{"name" => "Roll dice", "note" => "", "actions" => []},
      %{"name" => "Move token", "note" => "", "actions" => []}
    ]

    RuleMaven.Settings.put("turn_flow_#{game.id}", Jason.encode!(flow))
  end

  test "Next phase advances and keeps the wizard open", %{conn: conn} do
    user = setup_user("turnwiz")
    game = published_game_fixture(%{name: "Turn Wizard Game"})
    seed_turn_flow(game)

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    # Launch the wizard from the Play menu: it opens as an expanded tool panel,
    # starting on phase 1.
    html = render_click(view, "open_tool", %{"tool" => "turn"})

    assert html =~ ~s(data-tool-panel="turn")
    assert html =~ ~s(data-tool-state="expanded")
    assert html =~ "Phase 1 of 2"
    assert html =~ "Roll dice"

    # Click Next: phase advances to 2 and the panel stays expanded.
    html = view |> element("button[phx-click=turn_next]") |> render_click()

    assert html =~ "Phase 2 of 2"
    assert html =~ "Move token"
    assert html =~ ~s(data-tool-state="expanded")
  end
end
