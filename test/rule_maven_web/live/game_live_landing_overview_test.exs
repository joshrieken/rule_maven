defmodule RuleMavenWeb.GameLiveLandingOverviewTest do
  @moduledoc """
  Landing on a game's Q&A page shows the overview (start screen) even when the
  user already has question threads — a thread only opens when explicitly
  targeted via ?t=THREAD_ID. Pins the default-to-overview behavior so a future
  refactor doesn't silently reinstate auto-selecting the first thread.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games

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

  defp seed_thread(game, user) do
    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many dice do I roll?",
        answer: "You roll 3 dice.",
        promoted: false
      })

    ql
  end

  test "landing with existing threads shows the overview, not a thread", %{conn: conn} do
    user = setup_user("land_overview")
    game = published_game_fixture(%{name: "Landing Game"})
    seed_thread(game, user)

    conn = login(conn, user)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    # Start-screen heading renders; the thread's answer does not.
    assert html =~ "Landing Game Rules"
    refute html =~ "You roll 3 dice."
  end

  test "?t= explicitly opens the targeted thread", %{conn: conn} do
    user = setup_user("land_thread")
    game = published_game_fixture(%{name: "Landing Thread Game"})
    ql = seed_thread(game, user)

    conn = login(conn, user)

    {:ok, _view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}"
      )

    assert html =~ "You roll 3 dice."
  end

  test "?t= with an unknown thread falls back to the overview", %{conn: conn} do
    user = setup_user("land_unknown")
    game = published_game_fixture(%{name: "Landing Unknown Game"})
    ql = seed_thread(game, user)

    conn = login(conn, user)

    {:ok, _view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id + 999)}"
      )

    assert html =~ "Landing Unknown Game Rules"
    refute html =~ "You roll 3 dice."
  end

  test "patching to ?start=1 from an open thread survives", %{conn: conn} do
    user = setup_user("land_patch")
    game = published_game_fixture(%{name: "Landing Patch Game"})
    ql = seed_thread(game, user)
    token = RuleMaven.Hashid.encode(game.id)

    conn = login(conn, user)

    {:ok, view, _html} =
      live(conn, ~p"/games/#{token}?t=#{RuleMaven.Hashid.encode(ql.id)}")

    html = render_patch(view, ~p"/games/#{token}?start=1")

    assert html =~ "Landing Patch Game Rules"
  end
end
