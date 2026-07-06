defmodule RuleMavenWeb.GameLiveLlmTraceTest do
  @moduledoc """
  Admin-only "LLM trace" panel in the Q&A view: per-question llm_logs calls
  with model, tokens, cost and duration (see LLM.calls_for_question/1).
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
          %{username: "#{prefix}_user", email: "#{prefix}_user@test.com", password: "password1234"},
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
        visibility: "private"
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

  test "admin can open the LLM trace and see the recorded calls", %{conn: conn} do
    admin = create_user("trace_admin", %{role: "admin"})
    game = published_game_fixture(%{name: "Trace Game"})
    ql = answered_question(game, admin)
    trace_row(ql.id)

    conn = login(conn, admin)
    {:ok, view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    assert html =~ "LLM trace"

    html = render_click(view, "toggle_llm_trace", %{"id" => to_string(ql.id)})

    assert html =~ "grounding_critic"
    assert html =~ "google/gemini-2.5-flash"
    assert html =~ "1.2s"
    assert html =~ "1 call"
  end

  test "empty trace shows the no-calls message", %{conn: conn} do
    admin = create_user("trace_admin2", %{role: "admin"})
    game = published_game_fixture(%{name: "Trace Game 2"})
    ql = answered_question(game, admin)

    conn = login(conn, admin)
    {:ok, view, _html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    html = render_click(view, "toggle_llm_trace", %{"id" => to_string(ql.id)})

    assert html =~ "No LLM calls recorded"
  end

  test "non-admin sees no LLM trace button and the event is a no-op", %{conn: conn} do
    viewer = create_user("trace_viewer")
    game = published_game_fixture(%{name: "Trace Game 3"})
    ql = answered_question(game, viewer)
    trace_row(ql.id)

    conn = login(conn, viewer)
    {:ok, view, html} = live(conn, ~p"/games/#{RuleMaven.Hashid.encode(game.id)}")

    refute html =~ "LLM trace"

    html = render_click(view, "toggle_llm_trace", %{"id" => to_string(ql.id)})
    refute html =~ "grounding_critic"
  end
end
