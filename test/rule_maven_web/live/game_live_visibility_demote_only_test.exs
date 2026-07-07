defmodule RuleMavenWeb.GameLiveVisibilityDemoteOnlyTest do
  @moduledoc """
  The admin 🌐 visibility toggle is demote-only: rows reach the community pool
  via vote quorum or admin verify, never a manual promote (which would render
  identically to a crowd-promoted row).
  """

  use RuleMavenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Repo

  # Demoting via update_question_visibility enqueues SettleVotesWorker, so Oban
  # must be supervised here (same pattern as standing_live_test.exs).
  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_admin(prefix) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "#{prefix}_user",
        email: "#{prefix}_user@test.com",
        password: "password1234",
        role: "admin"
      })

    user
  end

  defp log(game, user, attrs) do
    {:ok, q} =
      Games.log_question(
        Map.merge(
          %{
            game_id: game.id,
            user_id: user.id,
            question: "How does scoring work?",
            answer: "Count the points.",
            visibility: "private"
          },
          attrs
        )
      )

    q
  end

  test "toggle demotes a community row to private", %{conn: conn} do
    admin = create_admin("vd_admin")
    game = published_game_fixture(%{name: "Demote Game"})
    q = log(game, admin, %{visibility: "community", pooled: true})

    conn = login(conn, admin)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    render_click(view, "toggle_question_visibility", %{"id" => to_string(q.id)})

    assert Repo.reload!(q).visibility == "private"
  end

  test "toggle never promotes a private row (forged event is a no-op)", %{conn: conn} do
    admin = create_admin("vd_admin2")
    game = published_game_fixture(%{name: "No Promote Game"})
    q = log(game, admin, %{visibility: "private"})

    conn = login(conn, admin)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    render_click(view, "toggle_question_visibility", %{"id" => to_string(q.id)})

    assert Repo.reload!(q).visibility == "private"
  end

  test "visibility button renders only for community rows", %{conn: conn} do
    admin = create_admin("vd_admin3")
    game = published_game_fixture(%{name: "Button Render Game"})
    log(game, admin, %{visibility: "private"})

    conn = login(conn, admin)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    refute html =~ "Make community-visible"
    refute html =~ ~s(phx-click="toggle_question_visibility")

    game2 = published_game_fixture(%{name: "Button Render Game 2", bgg_id: 43})
    q2 = log(game2, admin, %{visibility: "community", pooled: true})

    {:ok, view2, _} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game2.id)}")
    html2 = render(view2)

    assert html2 =~ ~s(phx-click="toggle_question_visibility")
    assert html2 =~ "Remove from community"
    assert Repo.reload!(q2).visibility == "community"
  end
end
