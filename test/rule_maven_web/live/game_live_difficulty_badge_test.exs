defmodule RuleMavenWeb.GameLiveDifficultyBadgeTest do
  @moduledoc """
  Task 5 added the BGG-weight-derived `difficulty_bucket/1` helper but nothing
  rendered it yet. This drives the real show page and asserts the pill badge
  appears when the game (or a selected expansion) has a weight, and is absent
  when there's no weight to bucket.
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

  test "renders difficulty badge when game has a weight", %{conn: conn} do
    user = setup_user("badge_present")
    game = published_game_fixture(%{name: "Weighted Game", weight: 3.2})

    conn = login(conn, user)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    assert html =~ "Medium"
    assert html =~ "3.2"
    assert html =~ "difficulty-badge"
  end

  test "renders difficulty badge on the games list", %{conn: conn} do
    user = setup_user("badge_index")
    _game = published_game_fixture(%{name: "Indexed Weighted Game", weight: 3.2})

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/")

    # The list stays hidden until the search hook restores its saved value on
    # connect; fire it manually the way the JS hook would.
    html = render_hook(view, "restore_search", %{"value" => ""})

    assert html =~ "difficulty-badge"
    assert html =~ "3.2"
    assert html =~ "Medium"
  end

  test "renders Medium-Heavy at the 4.2 boundary (not Heavy)", %{conn: conn} do
    user = setup_user("badge_boundary")
    game = published_game_fixture(%{name: "Boundary Game", weight: 4.2})

    conn = login(conn, user)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    assert html =~ "Medium-Heavy"
  end

  test "hides difficulty badge when game has no weight", %{conn: conn} do
    user = setup_user("badge_absent")
    game = published_game_fixture(%{name: "Unweighted Game", weight: nil})

    conn = login(conn, user)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    refute html =~ ">Medium<"
    refute html =~ ">Medium-Light<"
    refute html =~ ">Medium-Heavy<"
    refute html =~ ">Light<"
    refute html =~ ">Heavy<"
  end
end
