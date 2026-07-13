defmodule RuleMavenWeb.GameLive.ShowTest do
  @moduledoc """
  The fresh-ask path through the real composer form: a submitted ask must be
  born unbrowsable so PublishCheckWorker keeps its gate on the one path real
  users actually hit.
  """

  # Submitting "ask" enqueues AskWorker via Oban.insert/1, which needs a named
  # instance (Oban isn't supervised in test) — not async.
  use RuleMavenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
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

  test "a solo ask submitted through the real form is born unbrowsable", %{conn: conn} do
    # Regression: the "ask" event handler used to pass `browsable: is_nil(group_id)`
    # explicitly into the insert, which is `true` for a solo ask — bypassing
    # QuestionLog.default_unbrowsable/1 entirely (an explicit param always wins) and
    # defeating PublishCheckWorker's whole gate on the one path real users actually
    # hit. Every test elsewhere in this branch drives AskWorker.perform/1 or
    # Games.log_question/1 directly, never this LiveView event, so the bug was
    # invisible to the rest of the suite.
    user = create_user("solo_gate")
    game = published_game_fixture(%{bgg_id: 305})
    conn = login(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")

    lv
    |> form("#ask-form", question: "How many cards do we draw each turn?")
    |> render_submit()

    [ql] = RuleMaven.Repo.all(RuleMaven.Games.QuestionLog)
    refute ql.browsable, "a fresh solo ask must start unbrowsable pending PublishCheckWorker"
  end
end
