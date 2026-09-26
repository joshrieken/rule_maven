defmodule RuleMavenWeb.GameLive.SwitchThreadOutOfWindowTest do
  # The sidebar can list questions that aren't in the socket's cached @threads
  # window (admin full-history search, rows that appear after mount). Clicking
  # one used to be a silent no-op until a page refresh rebuilt @threads.
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  test "clicking a question outside the cached thread window opens it", %{conn: conn} do
    %{game: game, user: user} = qa_thread_fixture(question_count: 1)
    {:ok, view, _html} = conn |> login(user) |> live(~p"/games/#{game}")

    # Asked after mount (e.g. another tab), so it isn't in this socket's @threads.
    {:ok, late} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "A question asked after the page loaded?",
        answer: "Late answer."
      })

    render_click(view, "switch_thread", %{"id" => to_string(late.id)})

    assert_patch(view, ~p"/games/#{game}?t=#{RuleMaven.Hashid.encode(late.id)}")

    assert view |> element(".qa-question__text") |> render() =~
             "A question asked after the page loaded?"
  end

  test "an id the viewer can't see is still a no-op", %{conn: conn} do
    %{game: game, user: user} = qa_thread_fixture(question_count: 1)

    {:ok, other} =
      RuleMaven.Users.create_user(%{
        username: "switch_other_#{System.unique_integer([:positive])}",
        email: "switch_other_#{System.unique_integer([:positive])}@test.com",
        password: "password1234"
      })

    {:ok, private} =
      Games.log_question(%{
        game_id: game.id,
        user_id: other.id,
        question: "Private?",
        answer: "Secret."
      })

    {:ok, view, _html} = conn |> login(user) |> live(~p"/games/#{game}")
    render_click(view, "switch_thread", %{"id" => to_string(private.id)})

    refute render(view) =~ "Secret."
  end
end
