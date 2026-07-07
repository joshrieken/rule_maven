defmodule RuleMavenWeb.GameLiveErrorRetryTest do
  @moduledoc """
  Failed ("⚠️ ...") answers must give regular players a way out: a bounded
  Retry button for transient failures, a shorten-hint for over-long questions,
  and an auto-reported notice once retries are exhausted. Previously the only
  retry affordance lived in the admin-only action row, dead-ending players.
  """

  # Not async: the retry path enqueues AskWorker via Oban.insert/1, which
  # needs a named instance (Oban isn't supervised in test) — same convention
  # as GameLiveNotMyQuestionTest.
  use RuleMavenWeb.ConnCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.QuestionLog

  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp setup_error_thread(prefix, attrs) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "#{prefix}_user",
        email: "#{prefix}_user@test.com",
        password: "password1234"
      })

    game = published_game_fixture(%{name: "#{prefix} Game"})

    {:ok, ql} =
      Games.log_question(
        Map.merge(
          %{
            game_id: game.id,
            user_id: user.id,
            question: "How many dice do I roll?",
            answer: "⚠️ The AI returned an unexpected response format. Please retry.",
            visibility: "private"
          },
          attrs
        )
      )

    {user, game, ql}
  end

  defp open_thread(conn, user, game, ql) do
    conn = login(conn, user)

    live(
      conn,
      ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}"
    )
  end

  test "player sees a Retry button on a retryable failed answer", %{conn: conn} do
    {user, game, ql} = setup_error_thread("err_retry", %{error_kind: "format"})
    {:ok, _view, html} = open_thread(conn, user, game, ql)

    assert html =~ "↻ Retry"
  end

  test "player retry resubmits and carries the retry count forward", %{conn: conn} do
    {user, game, ql} = setup_error_thread("err_resub", %{error_kind: "format"})
    {:ok, view, _html} = open_thread(conn, user, game, ql)

    render_click(view, "retry_question", %{"id" => to_string(ql.id)})

    refute Repo.get(QuestionLog, ql.id)
    replacement = Repo.one(QuestionLog)
    assert replacement.answer == "Thinking..."
    assert replacement.error_retries == 1
  end

  test "exhausted retries show the auto-reported notice, not a Retry button", %{conn: conn} do
    {user, game, ql} =
      setup_error_thread("err_done", %{
        error_kind: "format",
        error_retries: Games.error_retry_limit()
      })

    {:ok, view, html} = open_thread(conn, user, game, ql)

    assert html =~ "reported to the admins"
    refute html =~ "↻ Retry"

    # The server enforces the limit too — a forged click must not resubmit.
    render_click(view, "retry_question", %{"id" => to_string(ql.id)})
    assert Repo.get(QuestionLog, ql.id)
    assert Repo.aggregate(QuestionLog, :count) == 1
  end

  test "too_long shows the shorten hint instead of Retry", %{conn: conn} do
    {user, game, ql} =
      setup_error_thread("err_long", %{
        answer: "⚠️ Question too long for the AI to process. Try a shorter question.",
        error_kind: "too_long"
      })

    {:ok, _view, html} = open_thread(conn, user, game, ql)

    assert html =~ "Try asking a shorter question."
    refute html =~ "↻ Retry"
  end
end
