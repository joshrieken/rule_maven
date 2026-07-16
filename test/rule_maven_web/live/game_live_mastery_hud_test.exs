defmodule RuleMavenWeb.GameLiveMasteryHudTest do
  @moduledoc """
  Drives the real show page and asserts the per-game mastery HUD: the XP bar
  renders, a {:mastery_awarded, …} broadcast updates the bar and flashes the
  toast, and a level-up pushes the client event that fires the confetti moment.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Progress

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp setup_user(prefix) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "#{prefix}_user_#{System.unique_integer([:positive])}",
        email: "#{prefix}_#{System.unique_integer([:positive])}@test.com",
        password: "password1234"
      })

    user
  end

  test "renders the mastery HUD bar on the game page", %{conn: conn} do
    user = setup_user("hud")
    game = published_game_fixture(%{name: "HUD Game"})

    conn = login(conn, user)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    assert html =~ "mastery-hud"
    assert html =~ "Lv 0"
  end

  test "a mastery_awarded broadcast updates the bar and shows the toast", %{conn: conn} do
    user = setup_user("award")
    game = published_game_fixture(%{name: "Award Game"})

    # Pre-earn so the reload inside the handler reflects real XP.
    {:awarded, _} = Progress.award_ask(user.id, game.id, "seed-1")

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    send(
      view.pid,
      {:mastery_awarded,
       %{
         user_id: user.id,
         game_id: game.id,
         question_log_id: 1,
         xp_delta: 15,
         xp: 15,
         level: 0,
         level_up: false,
         unlocked: []
       }}
    )

    html = render(view)
    assert html =~ "+15 XP"
    assert html =~ "mastery-hud__fill"
  end

  test "a level-up broadcast pushes the confetti event", %{conn: conn} do
    user = setup_user("levelup")
    game = published_game_fixture(%{name: "LevelUp Game"})

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    send(
      view.pid,
      {:mastery_awarded,
       %{
         user_id: user.id,
         game_id: game.id,
         question_log_id: 2,
         xp_delta: 15,
         xp: 60,
         level: 1,
         level_up: true,
         unlocked: ["merchant"]
       }}
    )

    assert_push_event(view, "mastery:level_up", %{level: 1, unlocked: ["merchant"]})
  end

  test "ignores a mastery_awarded broadcast for a different user", %{conn: conn} do
    me = setup_user("me")
    other = setup_user("other")
    game = published_game_fixture(%{name: "Scoped Game"})

    conn = login(conn, me)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    send(
      view.pid,
      {:mastery_awarded,
       %{
         user_id: other.id,
         game_id: game.id,
         question_log_id: 3,
         xp_delta: 15,
         xp: 15,
         level: 0,
         level_up: false,
         unlocked: []
       }}
    )

    html = render(view)
    refute html =~ "+15 XP"
  end
end
