defmodule RuleMavenWeb.GameLive.GroupPanelTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures
  import RuleMaven.GroupsFixtures

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

  defp open_group_feed(lv) do
    lv |> element("[data-testid='group-feed-toggle']") |> render_click()
  end

  test "with a group active, the panel lists prior questions for this game, attributed", %{
    conn: conn
  } do
    user = create_user("lister")
    game = published_game_fixture(%{bgg_id: 201})
    grp = group_fixture(user)

    {:ok, _ql} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "how many cards do we start with",
        answer: "seven cards each",
        visibility: "private",
        group_id: grp.id
      })

    conn = login(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    lv |> element("[phx-value-group='#{Phoenix.Param.to_param(grp)}']") |> render_click()

    html = open_group_feed(lv)

    assert html =~ "how many cards do we start with"
    assert html =~ "seven cards each"
    assert html =~ user.username
  end

  test "live-appends on a matching :ask_complete broadcast", %{conn: conn} do
    user = create_user("append")
    game = published_game_fixture(%{bgg_id: 202})
    grp = group_fixture(user)
    conn = login(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    lv |> element("[phx-value-group='#{Phoenix.Param.to_param(grp)}']") |> render_click()
    open_group_feed(lv)

    {:ok, ql} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "fresh group q",
        answer: "the answer",
        visibility: "private",
        group_id: grp.id
      })

    send(lv.pid, {:ask_complete, %{question_log_id: ql.id, group_id: grp.id}})

    assert render(lv) =~ "fresh group q"
  end

  test "an :ask_complete for a different group does not alter this group's feed", %{conn: conn} do
    user = create_user("otherg")
    game = published_game_fixture(%{bgg_id: 203})
    grp = group_fixture(user)
    other_grp = group_fixture(user, %{name: "Other Crew"})
    conn = login(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    lv |> element("[phx-value-group='#{Phoenix.Param.to_param(grp)}']") |> render_click()
    open_group_feed(lv)

    {:ok, ql} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "other group question",
        answer: "other group answer",
        visibility: "private",
        group_id: other_grp.id
      })

    send(lv.pid, {:ask_complete, %{question_log_id: ql.id, group_id: other_grp.id}})

    refute render(lv) =~ "other group question"
  end

  test "a group ask still updates the asker's own conversation (existing handler not shadowed)",
       %{conn: conn} do
    user = create_user("selfconv")
    game = published_game_fixture(%{bgg_id: 204})
    grp = group_fixture(user)

    {:ok, ql} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "own conversation question",
        answer: "Thinking...",
        visibility: "private",
        group_id: grp.id
      })

    conn = login(conn, user)

    # `?t=` opens this question as the active thread, same as the persona-
    # direct suite does — that's what makes the existing handler's targeted
    # `conversation` update kick in below.
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/games/#{RuleMaven.Hashid.encode(game.id)}?t=#{RuleMaven.Hashid.encode(ql.id)}"
      )

    lv |> element("[phx-value-group='#{Phoenix.Param.to_param(grp)}']") |> render_click()

    {:ok, ql} =
      RuleMaven.Games.log_question_update(ql, %{answer: "own conversation answer"})

    send(lv.pid, {:ask_complete, %{question_log_id: ql.id, group_id: grp.id}})

    html = render(lv)
    # The asker's own conversation still updates with the real answer...
    assert html =~ "own conversation answer"
    # ...and the group feed also refreshed for the same broadcast.
    html = open_group_feed(lv)
    assert html =~ "own conversation question"
  end

  test "no active group renders no panel toggle", %{conn: conn} do
    user = create_user("nogroup")
    game = published_game_fixture(%{bgg_id: 205})
    _grp = group_fixture(user)
    conn = login(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/games/#{game}")

    refute html =~ "group-feed-toggle"
  end

  test "the feed does not show another group's rows, nor rows from a different game", %{
    conn: conn
  } do
    user = create_user("scoped")
    game = published_game_fixture(%{bgg_id: 206})
    other_game = published_game_fixture(%{bgg_id: 207})
    grp = group_fixture(user)
    other_grp = group_fixture(user, %{name: "Other Crew 2"})

    {:ok, _} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "belongs to other group",
        answer: "answer a",
        visibility: "private",
        group_id: other_grp.id
      })

    {:ok, _} =
      RuleMaven.Games.log_question(%{
        game_id: other_game.id,
        user_id: user.id,
        question: "belongs to other game",
        answer: "answer b",
        visibility: "private",
        group_id: grp.id
      })

    {:ok, _} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "belongs right here",
        answer: "answer c",
        visibility: "private",
        group_id: grp.id
      })

    conn = login(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    lv |> element("[phx-value-group='#{Phoenix.Param.to_param(grp)}']") |> render_click()
    open_group_feed(lv)

    # Scoped to the panel itself: the user's own thread sidebar legitimately
    # lists every question they've asked for this game regardless of which
    # group was active at the time (that list is not a group concept), so
    # asserting against the whole page would false-positive on it. The group
    # feed panel is what must never leak another group's (or another game's)
    # rows.
    panel = lv |> element("[data-tool-panel='group_feed']") |> render()

    assert panel =~ "belongs right here"
    refute panel =~ "belongs to other group"
    refute panel =~ "belongs to other game"
  end
end
