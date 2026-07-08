defmodule RuleMavenWeb.GameLiveTurnWizardTest do
  @moduledoc """
  The "What can I do now?" turn wizard lives in a <details> element. Its open
  state is server-controlled (`turn_open`) so a LiveView re-render on phase
  navigation doesn't strip the browser-set `open` attribute and collapse the
  wizard. Pins that clicking Next/Back advances the phase AND keeps it open.
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
    {:ok, view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    # Wizard renders, starts on phase 1, and is collapsed (no `open`).
    assert html =~ "Phase 1 of 2"
    assert html =~ "Roll dice"

    # Click Next: phase advances to 2 AND the <details> re-renders with `open`
    # (the bug: it lost `open` on patch and visually collapsed).
    html = view |> element("button[phx-click=turn_next]") |> render_click()

    assert html =~ "Phase 2 of 2"
    assert html =~ "Move token"
    assert html =~ ~r/<details[^>]*\bopen\b/
  end
end
