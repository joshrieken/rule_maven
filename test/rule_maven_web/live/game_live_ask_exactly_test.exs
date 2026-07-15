defmodule RuleMavenWeb.GameLiveAskExactlyTest do
  @moduledoc """
  "Ask exactly this" is the single escape hatch when a served answer didn't fit
  what the asker meant — either the pool matched a similar-but-different
  neighbor, or the normalizer rewrote the wording. Clicking it bumps the matched
  row's mismatch_count (the pool source for a pool copy), writes a
  `question.ask_verbatim` audit entry, and re-asks the LITERAL wording with
  skip_pool + skip_normalize so neither a rewrite nor a wrong pool match recurs.
  """

  # Not async: the click path enqueues AskWorker via Oban.insert/1, which
  # needs a named instance (Oban isn't supervised in test).
  use RuleMavenWeb.ConnCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Audit
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
        promoted: true,
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
        promoted: false
      })

    {source, copy}
  end

  test "button shows on a pool-hit answer; click records mismatch + re-asks verbatim",
       %{conn: conn} do
    user = setup_user("ax_pool")
    game = published_game_fixture(%{name: "AX Pool Game"})
    {source, copy} = seed_pool_hit(game, user)

    conn = login(conn, user)

    # ?t= pins the active thread to the user's pool-hit copy — the community
    # source row is a separate thread and can win the default selection.
    {:ok, view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(copy.id)}"
      )

    # The escape hatch lives on the full-question sheet now — opened by
    # tapping the pinned question — not inline on the question bar.
    refute html =~ "Ask exactly what I typed"

    sheet = view |> element("button.qa-question__text") |> render_click()
    assert sheet =~ "Ask exactly what I typed"

    view
    |> element("button[phx-click='ask_exactly'][phx-value-id='#{copy.id}']")
    |> render_click()

    # Mismatch lands on the POOL SOURCE row, otherwise untouched.
    source_after = Repo.get!(QuestionLog, source.id)
    assert source_after.mismatch_count == 1
    assert source_after.answer == "No — trades happen only on your own turn."

    # The served copy was resubmitted fresh: old row replaced by a pending one
    # carrying the asker's LITERAL wording.
    assert Repo.get(QuestionLog, copy.id) == nil

    pending =
      Repo.one!(
        from(q in QuestionLog,
          where: q.game_id == ^game.id and q.user_id == ^user.id and q.answer == "Thinking...",
          limit: 1
        )
      )

    assert pending.question == "Can I trade during someone else's turn?"

    # Re-ask is verbatim + uncached.
    assert_enqueued(
      worker: RuleMaven.Workers.AskWorker,
      args: %{question_log_id: pending.id, skip_pool: true, skip_normalize: true}
    )

    # Bad-match/rewrite signal is on the audit trail for admins.
    assert [entry | _] = Audit.list(action: "question.ask_verbatim")
    assert entry.target_id == copy.id
  end

  test "button shows on a normalized (non-pool) answer and re-asks the raw wording",
       %{conn: conn} do
    user = setup_user("ax_norm")
    game = published_game_fixture(%{name: "AX Norm Game"})

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "how many cards do i draw",
        cleaned_question: "How many cards does a player draw per turn?",
        answer: "You draw two cards.",
        llm_provider: "openrouter",
        llm_model: "some-model",
        promoted: false
      })

    conn = login(conn, user)

    {:ok, view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}"
      )

    # The bar flags the rewrite; the disclosure + escape hatch open with the
    # full-question sheet (tap the pinned question).
    assert html =~ "edited"

    sheet = view |> element("button.qa-question__text") |> render_click()
    assert sheet =~ "We searched"
    assert sheet =~ "You asked"
    assert sheet =~ "Ask exactly what I typed"

    view
    |> element("button[phx-click='ask_exactly'][phx-value-id='#{ql.id}']")
    |> render_click()

    pending =
      Repo.one!(
        from(q in QuestionLog,
          where: q.game_id == ^game.id and q.user_id == ^user.id and q.answer == "Thinking...",
          limit: 1
        )
      )

    # Verbatim: the fresh row carries the RAW text, not the cleaned form.
    assert pending.question == "how many cards do i draw"

    assert_enqueued(
      worker: RuleMaven.Workers.AskWorker,
      args: %{question_log_id: pending.id, skip_pool: true, skip_normalize: true}
    )
  end

  test "another user's question id is a no-op", %{conn: conn} do
    owner = setup_user("ax_owner")
    other = setup_user("ax_other")
    game = published_game_fixture(%{name: "AX Foreign Game"})
    {source, copy} = seed_pool_hit(game, owner)

    conn = login(conn, other)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    render_click(view, "ask_exactly", %{"id" => to_string(copy.id)})

    assert Repo.get!(QuestionLog, source.id).mismatch_count == 0
    assert Repo.get!(QuestionLog, copy.id).answer == source.answer
    assert Audit.list(action: "question.ask_verbatim") == []
  end

  test "no button on a fresh answer that was neither pooled nor rewritten", %{conn: conn} do
    user = setup_user("ax_fresh")
    game = published_game_fixture(%{name: "AX Fresh Game"})

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many cards do I draw?",
        answer: "Draw three cards.",
        llm_provider: "openrouter",
        llm_model: "some-model",
        promoted: false
      })

    conn = login(conn, user)

    {:ok, view, html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(q.id)}"
      )

    refute html =~ "Ask exactly what I typed"

    # Even on the full-question sheet: fresh, unrewritten, non-pool answers
    # get no escape hatch.
    sheet = view |> element("button.qa-question__text") |> render_click()
    refute sheet =~ "Ask exactly what I typed"
    refute sheet =~ "phx-click=\"ask_exactly\""
  end
end
