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

    # One answer-pane, one chip showing a "N / 2" style pager.
    assert html =~ ~s(class="answer-pane")
    assert has_element?(view, ".qa-chip__pager", "2")
    # The active answer's body is inside the one scroll region.
    assert view |> element(".answer-pane") |> render() =~ "Test answer"
  end

  test "pager next/prev swaps the active question",
       %{conn: conn, game: game, user: user, thread_ids: thread_ids} do
    {:ok, view, _html} = conn |> login(user) |> visit_newest(game, thread_ids)

    # Landing on the newest thread puts the pager at index 0 (sidebar order is
    # recency-desc — see `sort_thread_summaries/1`), so "next" is the enabled
    # direction here; "prev" is disabled at the top of the list.
    q1 = view |> element(".qa-chip__text") |> render()
    view |> element("button[phx-click=qa_next]") |> render_click()
    q0 = view |> element(".qa-chip__text") |> render()
    refute q0 == q1
  end

  test "tapping the chip opens the full-question overlay",
       %{conn: conn, game: game, user: user, thread_ids: thread_ids} do
    {:ok, view, _html} = conn |> login(user) |> visit_newest(game, thread_ids)

    refute has_element?(view, ".qa-overlay")
    view |> element(".qa-chip__text") |> render_click()
    assert has_element?(view, ".qa-overlay__sheet")
    view |> element(".qa-overlay") |> render_click()
    refute has_element?(view, ".qa-overlay")
  end
end
