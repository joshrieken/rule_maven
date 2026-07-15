defmodule RuleMavenWeb.GameLive.QaNoShiftTest do
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  # No `log_in_user/2` helper exists in this project; other GameLive tests
  # (e.g. show_test.exs) authenticate by seeding the plug session directly.
  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  setup do
    %{game: game, user: user, thread_ids: thread_ids} = qa_thread_fixture(question_count: 2)
    %{game: game, user: user, thread_ids: thread_ids}
  end

  # `/games/:id` alone lands on the overview (no active thread) — real
  # navigation to a specific Q&A goes through `?t=`, same as clicking a
  # thread in the sidebar or following a bookmarked link.
  defp visit_newest(conn, game, thread_ids) do
    newest = List.last(thread_ids)
    live(conn, ~p"/games/#{game}?t=#{RuleMaven.Hashid.encode(newest)}")
  end

  test "renders exactly one active Q&A with a pager, not an appended list",
       %{conn: conn, game: game, user: user, thread_ids: thread_ids} do
    {:ok, view, html} = conn |> login(user) |> visit_newest(game, thread_ids)

    # One answer-pane, one fixed question region showing a "N / 2" pager count.
    assert html =~ ~s(class="answer-pane")
    assert has_element?(view, ".qa-question__count", "2")
    # The active answer's body is inside the one scroll region.
    assert view |> element(".answer-pane") |> render() =~ "Test answer"
  end

  test "the question renders in the fixed top region, not as a bubble in the pane",
       %{conn: conn, game: game, user: user, thread_ids: thread_ids} do
    {:ok, view, _html} = conn |> login(user) |> visit_newest(game, thread_ids)

    # The question lives in the fixed .qa-question box on top...
    assert has_element?(view, ".qa-question .qa-question__text")
    # ...and its text is NOT repeated as a rendered body inside the user row in
    # the pane (the user row keeps only the escape-hatch controls, no question).
    refute has_element?(view, ".chat-msg-user .answer-in")
  end

  test "pager next/prev swaps the active question",
       %{conn: conn, game: game, user: user, thread_ids: thread_ids} do
    {:ok, view, _html} = conn |> login(user) |> visit_newest(game, thread_ids)

    # Landing on the newest thread puts the pager at index 0 (sidebar order is
    # recency-desc — see `sort_thread_summaries/1`), so "next" is the enabled
    # direction here; "prev" is disabled at the top of the list. The question
    # renders once, in the fixed top region — read it there.
    q1 = view |> element(".qa-question__text") |> render()
    view |> element("button[phx-click=qa_next]") |> render_click()
    q0 = view |> element(".qa-question__text") |> render()
    refute q0 == q1
  end

  test "tapping the question opens the full-question overlay",
       %{conn: conn, game: game, user: user, thread_ids: thread_ids} do
    {:ok, view, _html} = conn |> login(user) |> visit_newest(game, thread_ids)

    refute has_element?(view, ".qa-overlay")
    view |> element(".qa-question__text") |> render_click()
    assert has_element?(view, ".qa-overlay__sheet")
    view |> element(".qa-overlay") |> render_click()
    refute has_element?(view, ".qa-overlay")
  end

  test "the 'edited' badge renders OUTSIDE the clamped question text (so a long question can't clip it)",
       %{conn: conn, game: game, user: user} do
    # A rewritten question: what the user typed differs from the cleaned form
    # the UI displays back. `normalized?` fires, so the affordance must show.
    {:ok, ql} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "does the kight beat the archer even in a really long-winded question?",
        cleaned_question: "Does the knight beat the archer even in a really long-winded question?",
        answer: "Yes.",
        promoted: false
      })

    {:ok, view, _html} =
      conn
      |> login(user)
      |> live(~p"/games/#{game}?t=#{RuleMaven.Hashid.encode(ql.id)}")

    # The pill is a direct child of the bar, NOT nested in the 2-line-clamped,
    # overflow:hidden text button (where a long question would hide it).
    assert has_element?(view, ".qa-question > button.qa-question__edited")
    refute has_element?(view, ".qa-question__text .qa-question__edited")

    # Tapping the pill opens the compare overlay showing both forms.
    view |> element("button.qa-question__edited") |> render_click()
    sheet = view |> element(".qa-overlay__sheet") |> render()
    assert sheet =~ "We searched"
    assert sheet =~ "You asked"
    assert sheet =~ "kight"
  end

  test "pager and answer-pane share one vertical column wrapper",
       %{conn: conn, game: game, user: user, thread_ids: thread_ids} do
    {:ok, view, _html} = conn |> login(user) |> visit_newest(game, thread_ids)
    # .qa-column wraps both the fixed question region and the scroll region.
    assert has_element?(view, ".qa-column .qa-question")
    assert has_element?(view, ".qa-column .answer-pane")
  end
end
