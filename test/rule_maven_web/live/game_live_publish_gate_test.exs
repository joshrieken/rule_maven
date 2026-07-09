defmodule RuleMavenWeb.GameLivePublishGateTest do
  @moduledoc """
  A game that hasn't been marked Ready can't be asked about by ordinary users —
  admins can, so they can test it before publishing. The gate lives in Show's
  `ask` handler; the Prepare page no longer carries an "Ask questions" link to
  gate on, so this drives the real event instead.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Repo
  alias RuleMaven.Games.QuestionLog

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp user!(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{
            username: "#{prefix}_user",
            email: "#{prefix}_user@test.com",
            password: "password1234"
          },
          attrs
        )
      )

    user
  end

  test "asking an unpublished game is blocked for ordinary users", %{conn: conn} do
    user = user!("gate_plain")
    game = game_fixture(%{name: "Unready Game"})

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    html = render_submit(view, "ask", %{"question" => "How many dice do I roll?"})

    assert html =~ "isn&#39;t ready yet" or html =~ "isn't ready yet"
    assert Repo.aggregate(QuestionLog, :count) == 0
  end
end
