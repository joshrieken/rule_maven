defmodule RuleMavenWeb.GameLive.ShowTest do
  @moduledoc """
  Task 6, Gate 4 (per-ask override): the "Keep this in the crew" composer
  checkbox. Only rendered with a group active; checking it must flow into the
  Oban `AskWorker` job's `never_pool` arg on the fresh-ask path.
  """

  # Submitting "ask" enqueues AskWorker via Oban.insert/1, which needs a named
  # instance (Oban isn't supervised in test) — not async.
  use RuleMavenWeb.ConnCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures
  import RuleMaven.GroupsFixtures

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

  test "the composer toggle is hidden with no active group", %{conn: conn} do
    user = create_user("keep_nogrp")
    game = published_game_fixture(%{bgg_id: 301})
    conn = login(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/games/#{game}")

    refute html =~ "Keep this in the crew"
    refute html =~ "keep-in-crew-toggle"
  end

  test "the composer toggle appears once a group is active", %{conn: conn} do
    user = create_user("keep_grp")
    game = published_game_fixture(%{bgg_id: 302})
    grp = group_fixture(user)
    conn = login(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    lv |> element("[phx-value-group='#{Phoenix.Param.to_param(grp)}']") |> render_click()

    assert render(lv) =~ "Keep this in the crew"
  end

  test "checking the toggle and asking sends never_pool: true to AskWorker", %{conn: conn} do
    user = create_user("keep_send")
    game = published_game_fixture(%{bgg_id: 303})
    grp = group_fixture(user)
    conn = login(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    lv |> element("[phx-value-group='#{Phoenix.Param.to_param(grp)}']") |> render_click()

    lv |> element("#keep-in-crew-toggle") |> render_click()

    lv
    |> form("#ask-form", question: "Is Marcus cheating at this game?")
    |> render_submit()

    assert_enqueued(worker: RuleMaven.Workers.AskWorker, args: %{"never_pool" => true})
  end

  test "asking without checking the toggle does not force never_pool", %{conn: conn} do
    user = create_user("keep_unchecked")
    game = published_game_fixture(%{bgg_id: 304})
    grp = group_fixture(user)
    conn = login(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    lv |> element("[phx-value-group='#{Phoenix.Param.to_param(grp)}']") |> render_click()

    lv
    |> form("#ask-form", question: "How many cards do we draw each turn?")
    |> render_submit()

    assert_enqueued(worker: RuleMaven.Workers.AskWorker, args: %{"never_pool" => false})
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
