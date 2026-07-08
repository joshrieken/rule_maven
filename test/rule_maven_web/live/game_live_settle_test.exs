defmodule RuleMavenWeb.GameLiveSettleTest do
  @moduledoc """
  The ⚖️ argument settler composes two opposing player readings into one
  normal ask; the answer prompt's ARGUMENT SETTLING rule opens the reply with
  a verdict line. These tests cover the composition + validation, not the LLM.
  """

  # Not async: the ask path enqueues AskWorker via Oban.insert/1, which needs
  # a named instance — same convention as GameLiveNotMyQuestionTest.
  use RuleMavenWeb.ConnCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Repo

  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

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

  test "settle modal composes both sides into one ask", %{conn: conn} do
    game = published_game_fixture(%{name: "Settle Game"})
    user = setup_user("settle")
    conn = login(conn, user)

    {:ok, view, _html} = live(conn, ~p"/games/#{game}")

    html = render_click(view, "open_settle", %{})
    assert html =~ "Player A says"

    render_submit(view, "submit_settle", %{
      "a" => "You draw immediately.",
      "b" => "You wait until end of turn."
    })

    q = Repo.one(from q in QuestionLog, where: q.game_id == ^game.id)
    assert q.question =~ "Settle an argument"
    assert q.question =~ ~s(Player A says: "You draw immediately.")
    assert q.question =~ ~s(Player B says: "You wait until end of turn.")

    # Modal closed after submit.
    refute render(view) =~ "Player A says…"
  end

  test "both sides are required", %{conn: conn} do
    game = published_game_fixture(%{name: "Settle Game 2", bgg_id: 44})
    user = setup_user("settle2")
    conn = login(conn, user)

    {:ok, view, _html} = live(conn, ~p"/games/#{game}")
    render_click(view, "open_settle", %{})
    render_submit(view, "submit_settle", %{"a" => "Only one side.", "b" => "  "})

    assert Repo.aggregate(from(q in QuestionLog, where: q.game_id == ^game.id), :count) == 0
  end
end
