defmodule RuleMavenWeb.GameLiveAdminAllQuestionsTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{username: "#{prefix}_user", email: "#{prefix}_user@test.com", password: "password1234"},
          attrs
        )
      )

    user
  end

  test "admin sees other users' questions in the sidebar, tagged with their name", %{conn: conn} do
    admin = create_user("aq_admin", %{role: "admin"})
    other = create_user("aq_other")
    game = published_game_fixture(%{name: "All Questions Game"})

    {:ok, _} =
      Games.log_question(%{
        game_id: game.id,
        user_id: other.id,
        question: "How do I score?",
        answer: "Count the points.",
        visibility: "private"
      })

    conn = login(conn, admin)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    assert html =~ "How do I score?"
    assert html =~ other.username
  end

  test "non-admin does not see other users' questions in the sidebar", %{conn: conn} do
    viewer = create_user("aq_viewer")
    other = create_user("aq_other2")
    game = published_game_fixture(%{name: "All Questions Game 2"})

    {:ok, _} =
      Games.log_question(%{
        game_id: game.id,
        user_id: other.id,
        question: "Secret other question",
        answer: "Secret answer.",
        visibility: "private"
      })

    conn = login(conn, viewer)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    refute html =~ "Secret other question"
  end

  test "admin can search the sidebar by asker name", %{conn: conn} do
    admin = create_user("aq_admin2", %{role: "admin"})
    other = create_user("aq_searchable")
    game = published_game_fixture(%{name: "Search By Asker Game"})

    {:ok, _} =
      Games.log_question(%{
        game_id: game.id,
        user_id: other.id,
        question: "Totally unrelated text",
        answer: "Some answer.",
        visibility: "private"
      })

    conn = login(conn, admin)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    html = view |> element("form[phx-change='search']") |> render_change(%{"query" => other.username})

    assert html =~ "Totally unrelated text"
  end

  test "admin does not see a separate Not Covered section (refused folded into All Questions)",
       %{conn: conn} do
    admin = create_user("aq_admin3", %{role: "admin"})
    game = published_game_fixture(%{name: "Refused Fold Game"})

    {:ok, _} =
      Games.log_question(%{
        game_id: game.id,
        user_id: admin.id,
        question: "Not in the rulebook",
        answer: "Not covered.",
        refused: true,
        visibility: "private"
      })

    conn = login(conn, admin)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    assert html =~ "Not in the rulebook"
    refute html =~ "Not Covered"
  end
end
