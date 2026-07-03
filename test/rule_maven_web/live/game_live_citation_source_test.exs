defmodule RuleMavenWeb.GameLiveCitationSourceTest do
  @moduledoc """
  The citation figcaption always labeled the excerpt "Rulebook", even after
  Task 8 added `cited_source` to QuestionLog rows so multi-source games could
  attribute an answer to its actual document (e.g. "Official FAQ"). This
  drives a real connected LiveView over conversation history and asserts the
  figcaption uses `cited_source` when present, falling back to "Rulebook"
  for pre-existing rows where it's nil.
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

  test "figcaption shows the cited source label and page", %{conn: conn} do
    user = setup_user("cite_src")
    game = published_game_fixture(%{name: "Cite Src Game"})

    {:ok, _ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How does the FAQ handle ties?",
        answer: "Ties are broken by re-rolling.",
        cited_passage: "In case of a tie, re-roll all dice.",
        cited_page: 2,
        cited_source: "Official FAQ",
        visibility: "private"
      })

    conn = login(conn, user)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    assert html =~ "Official FAQ · p.2"
  end

  test "figcaption falls back to Rulebook when cited_source is nil", %{conn: conn} do
    user = setup_user("cite_nil")
    game = published_game_fixture(%{name: "Cite Nil Game"})

    {:ok, _ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many dice do I roll?",
        answer: "You roll 3 dice.",
        cited_passage: "Each player rolls three dice per turn.",
        cited_page: 5,
        visibility: "private"
      })

    conn = login(conn, user)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    assert html =~ "Rulebook · p.5"
  end
end
