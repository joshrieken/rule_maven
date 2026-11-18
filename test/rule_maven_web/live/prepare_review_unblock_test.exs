defmodule RuleMavenWeb.PrepareReviewUnblockTest do
  @moduledoc """
  A prepare pipeline paused on review used to look dead: Run remaining re-armed
  it and it re-paused within milliseconds, with only a "Running…" flash. Now
  Run remaining reports the blocker, and the edit page's "Mark reviewed" lets an
  admin accept a flagged page so the review step can pass.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.{Games, Readiness, Settings}
  alias RuleMaven.Games.Document
  alias RuleMaven.Repo

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  setup %{conn: conn} do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "review_unblock_#{System.unique_integer([:positive])}",
        email: "review_unblock_#{System.unique_integer([:positive])}@test.com",
        password: "password1234",
        role: "admin"
      })

    game =
      game_fixture(%{
        name: "Review Unblock #{System.unique_integer([:positive])}",
        bgg_id: System.unique_integer([:positive]),
        bgg_data: "<items/>",
        min_players: 2
      })

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        label: "Rulebook",
        full_text: "raw page 0",
        game_id: game.id,
        status: "published",
        page_count: 1,
        pages: [%{index: 0, text: "raw page 0", cleaned: "clean page 0", confidence: 0.3}]
      })
      |> Repo.insert()

    %{conn: login(conn, user), game: game, doc: doc}
  end

  test "Run remaining reports the review blocker instead of silently re-pausing", %{
    conn: conn,
    game: game
  } do
    Settings.put("readiness_auto_#{game.id}", "on")
    Settings.put("readiness_pause_#{game.id}", "needs_review")

    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")
    html = render_click(view, "resume", %{})

    assert html =~ "Still blocked: 1 low-confidence page needs review"
  end

  test "flagged pages are one click away, and Mark reviewed walks the queue", %{
    conn: conn,
    game: game,
    doc: doc
  } do
    # Add an advisory (cleanup-defect) page after the blocking one.
    {:ok, _} =
      doc
      |> Document.changeset(%{
        pages: [
          %{index: 0, printed: 1, text: "raw 0", cleaned: "clean 0", confidence: 0.3},
          %{index: 1, printed: 2, text: "raw 1", cleaned: "clean 1", confidence: 0.9},
          %{
            index: 2,
            printed: 3,
            text: "raw 2",
            cleaned: "clean 2",
            confidence: 0.9,
            cleanup_defects: ["JUNK: header"]
          }
        ]
      })
      |> Repo.update()

    refute Readiness.step_complete?(:review, game, Games.list_documents(game))

    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/edit?tab=manage")
    html = render(view)

    assert html =~ "2 of 3 page(s) flagged for review — 1 low-confidence blocking Ready"
    assert has_element?(view, ~s(button[phx-click="goto_source_page"][phx-value-page="0"]))
    assert has_element?(view, ~s(button[phx-click="goto_source_page"][phx-value-page="2"]))
    refute has_element?(view, ~s(button[phx-click="goto_source_page"][phx-value-page="1"]))

    assert has_element?(
             view,
             ~s(a[href$="/prepare"][data-phx-link="redirect"]),
             "Back to Prepare"
           )

    html = render_click(view, "mark_reviewed", %{"id" => "0", "page" => "0"})

    assert html =~ "Page marked reviewed — next flagged page."
    assert html =~ "none blocking Ready"
    # Landed on the next flagged page (index 2).
    assert has_element?(
             view,
             ~s(button[phx-click="goto_source_page"][phx-value-page="2"][aria-current="page"])
           )

    assert hd(Games.get_document!(doc.id).pages).reviewed
    assert Readiness.step_complete?(:review, game, Games.list_documents(game))
  end
end
