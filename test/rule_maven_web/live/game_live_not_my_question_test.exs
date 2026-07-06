defmodule RuleMavenWeb.GameLiveNotMyQuestionTest do
  @moduledoc """
  The pool matcher can serve a cached answer that answers a DIFFERENT question
  than the asker meant (a mismatch, distinct from a bad answer). Pool-hit
  answers carry a "Not my question" escape hatch: clicking it bumps the
  matched row's mismatch_count (threshold-tuning signal) and re-asks fresh
  with skip_pool, so the same wrong neighbor can't be served again.
  """

  # Not async: the click path enqueues AskWorker via Oban.insert/1, which
  # needs a named instance (Oban isn't supervised in test) — same convention
  # as GameLiveHouseRulesTest.
  use RuleMavenWeb.ConnCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
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

  defp seed_pool_hit(game, user) do
    {:ok, source} =
      Games.log_question(%{
        game_id: game.id,
        question: "Can I trade resources on another player's turn?",
        answer: "No — trades happen only on your own turn.",
        visibility: "community",
        pooled: true
      })

    {:ok, copy} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "Can I trade during someone else's turn?",
        answer: source.answer,
        llm_provider: "pool",
        llm_model: "cached",
        pool_source_id: source.id,
        visibility: "private"
      })

    {source, copy}
  end

  test "button shows on a pool-hit answer and click records mismatch + re-asks", %{conn: conn} do
    user = setup_user("nmq")
    game = published_game_fixture(%{name: "NMQ Game"})
    {source, copy} = seed_pool_hit(game, user)

    conn = login(conn, user)

    # ?t= pins the active thread to the user's pool-hit copy — the community
    # source row is a separate thread and can win the default selection.
    {:ok, view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(copy.id)}"
      )

    assert html =~ "Not my question"

    view
    |> element("button[phx-click='not_my_question'][phx-value-id='#{copy.id}']")
    |> render_click()

    # Mismatch landed on the POOL SOURCE row, untouched otherwise.
    source_after = Repo.get!(QuestionLog, source.id)
    assert source_after.mismatch_count == 1
    assert source_after.answer == "No — trades happen only on your own turn."

    # The served copy was resubmitted fresh: old row replaced by a pending one.
    assert Repo.get(QuestionLog, copy.id) == nil

    assert Repo.one(
             from(q in QuestionLog,
               where:
                 q.game_id == ^game.id and q.user_id == ^user.id and
                   q.answer == "Thinking...",
               select: count()
             )
           ) == 1
  end

  test "another user's question id is a no-op", %{conn: conn} do
    owner = setup_user("nmq_owner")
    other = setup_user("nmq_other")
    game = published_game_fixture(%{name: "NMQ Foreign Game"})
    {source, copy} = seed_pool_hit(game, owner)

    conn = login(conn, other)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    render_click(view, "not_my_question", %{"id" => to_string(copy.id)})

    assert Repo.get!(QuestionLog, source.id).mismatch_count == 0
    assert Repo.get!(QuestionLog, copy.id).answer == source.answer
  end

  test "no button on a fresh (non-pool) answer", %{conn: conn} do
    user = setup_user("nmq_fresh")
    game = published_game_fixture(%{name: "NMQ Fresh Game"})

    {:ok, _q} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many cards do I draw?",
        answer: "Draw three cards.",
        llm_provider: "openrouter",
        llm_model: "some-model",
        visibility: "private"
      })

    conn = login(conn, user)
    {:ok, _view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    refute html =~ "Not my question"
  end
end
