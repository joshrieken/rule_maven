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
        bgg_data: "<items/>"
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

  test "Mark reviewed on the edit page clears the review gate", %{
    conn: conn,
    game: game,
    doc: doc
  } do
    refute Readiness.step_complete?(:review, game, Games.list_documents(game))

    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/edit")
    html = render_click(view, "mark_reviewed", %{"id" => "0", "page" => "0"})

    assert html =~ "Page marked reviewed."
    assert hd(Games.get_document!(doc.id).pages).reviewed
    assert Readiness.step_complete?(:review, game, Games.list_documents(game))
  end
end
