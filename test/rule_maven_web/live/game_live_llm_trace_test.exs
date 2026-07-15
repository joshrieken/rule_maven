defmodule RuleMavenWeb.GameLiveLlmTraceTest do
  @moduledoc """
  Admin-only "🔍 Audit trail" modal in the Q&A view (AdminAuditTrailComponent):
  the recorded LLM calls (op, model, tokens, cost, duration — via
  LLM.calls_for_question/1) plus facts, cost and pool lineage.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.LLM.Log

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

  defp answered_question(game, user) do
    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many dice do I roll?",
        answer: "You roll 3 dice.",
        promoted: false
      })

    ql
  end

  defp trace_row(ql_id) do
    Repo.insert!(%Log{
      provider: "openrouter",
      model: "google/gemini-2.5-flash",
      operation: "grounding_critic",
      prompt_tokens: 1000,
      completion_tokens: 100,
      total_tokens: 1100,
      duration_ms: 1234,
      success: true,
      question_log_id: ql_id
    })
  end

  defp trace_row_cached(ql_id) do
    Repo.insert!(%Log{
      provider: "openrouter",
      model: "google/gemini-2.5-flash",
      operation: "ask",
      prompt_tokens: 15_000,
      completion_tokens: 400,
      total_tokens: 15_400,
      duration_ms: 2000,
      success: true,
      question_log_id: ql_id,
      detail: %{"cached_tokens" => 13_000}
    })
  end

  defp open_qa(conn, game, ql) do
    live(
      conn,
      ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}"
    )
  end

  test "admin can open the audit trail and see the recorded calls", %{conn: conn} do
    admin = create_user("trace_admin", %{role: "admin"})
    game = published_game_fixture(%{name: "Trace Game"})
    ql = answered_question(game, admin)
    trace_row(ql.id)

    conn = login(conn, admin)
    {:ok, view, html} = open_qa(conn, game, ql)

    assert html =~ "Audit trail"

    html = render_click(view, "open_audit", %{"id" => to_string(ql.id)})

    assert html =~ "Question audit trail"
    assert html =~ "grounding_critic"
    assert html =~ "google/gemini-2.5-flash"
    assert html =~ "1.2s"
    assert html =~ "1 LLM call"
    assert html =~ "Pool lineage"
  end

  test "cost splits billed vs. saved-by-cache when calls have cached tokens", %{conn: conn} do
    admin = create_user("trace_cache_admin", %{role: "admin"})
    game = published_game_fixture(%{name: "Cache Cost Game"})
    ql = answered_question(game, admin)
    trace_row_cached(ql.id)

    conn = login(conn, admin)
    {:ok, view, _html} = open_qa(conn, game, ql)

    html = render_click(view, "open_audit", %{"id" => to_string(ql.id)})

    assert html =~ "Billed (after cache)"
    assert html =~ "Saved by prompt cache"
    assert html =~ "List price (no cache)"
  end

  test "empty trace shows the no-calls message", %{conn: conn} do
    admin = create_user("trace_admin2", %{role: "admin"})
    game = published_game_fixture(%{name: "Trace Game 2"})
    ql = answered_question(game, admin)

    conn = login(conn, admin)
    {:ok, view, _html} = open_qa(conn, game, ql)

    html = render_click(view, "open_audit", %{"id" => to_string(ql.id)})

    assert html =~ "No LLM calls recorded"
  end

  test "audit trail shows pool lineage on the source row", %{conn: conn} do
    admin = create_user("trace_admin3", %{role: "admin"})
    game = published_game_fixture(%{name: "Trace Game Pool"})

    source = answered_question(game, admin)

    # A later ask served FROM the source via the pool.
    child = answered_question(game, admin)

    child
    |> Ecto.Changeset.change(pooled: true, pool_source_id: source.id)
    |> Repo.update!()

    conn = login(conn, admin)
    {:ok, view, _html} = open_qa(conn, game, source)

    html = render_click(view, "open_audit", %{"id" => to_string(source.id)})

    assert html =~ "Served 1 later ask"
  end

  test "non-admin sees no audit trail affordance", %{conn: conn} do
    viewer = create_user("trace_viewer")
    game = published_game_fixture(%{name: "Trace Game 3"})
    ql = answered_question(game, viewer)
    trace_row(ql.id)

    conn = login(conn, viewer)
    {:ok, _view, html} = open_qa(conn, game, ql)

    refute html =~ "Audit trail"
    refute html =~ "grounding_critic"
  end
end
