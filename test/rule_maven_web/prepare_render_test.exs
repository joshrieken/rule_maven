defmodule RuleMavenWeb.PrepareRenderTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  defp admin!(name) do
    {:ok, admin} =
      RuleMaven.Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "password1234",
        role: "admin"
      })

    admin
  end

  defp with_doc(game) do
    {:ok, doc} =
      RuleMaven.Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        pdf_path: "uploads/rulebooks/x.pdf",
        pages: []
      })

    doc
  end

  test "prepare page renders for a saved-but-unextracted source", %{conn: conn} do
    admin = admin!("prep_render_admin")
    game = game_fixture(%{name: "Prep Test Game", bgg_id: 7788})
    with_doc(game)

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})
    {:ok, _view, html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    assert html =~ "Prepare Prep Test Game"
    assert html =~ "Extract"
  end

  test "reset button is active and wipes the pipeline when there are no questions",
       %{conn: conn} do
    admin = admin!("prep_reset_admin")
    game = game_fixture(%{name: "Reset Me", bgg_id: 1122})
    with_doc(game)

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})
    {:ok, view, html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    assert html =~ "Reset all"
    assert has_element?(view, "button[phx-click=\"reset_all\"]")

    render_click(view, "reset_all")

    assert RuleMaven.Games.list_documents(game) == []
  end

  test "cleanup step offers a Clean up button once a source is extracted but not cleaned",
       %{conn: conn} do
    admin = admin!("prep_clean_admin")
    # BGG is the first required step now, so it must be pulled before the
    # cleanup step becomes actionable.
    game = game_fixture(%{name: "Cleanable Game", bgg_data: "<items/>"})

    {:ok, _doc} =
      RuleMaven.Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        pdf_path: "uploads/rulebooks/x.pdf",
        full_text: "some rules",
        # Extracted (page has text) and not flagged for review (confidence nil),
        # but not yet cleaned — so the cleanup step is actionable.
        pages: [%{index: 0, sheet: 1, printed: 1, text: "some rules", cleaned: nil}]
      })

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})
    {:ok, view, html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    assert html =~ "Clean up"
    assert has_element?(view, "button[phx-click=\"clean_all\"]")
  end

  test "no Review link while the source is unextracted (review blocked)", %{conn: conn} do
    admin = admin!("prep_noreview_admin")
    game = game_fixture(%{name: "Unextracted Prep"})

    {:ok, _doc} =
      RuleMaven.Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        pdf_path: "uploads/rulebooks/x.pdf",
        full_text: nil,
        pages: [%{index: 0, sheet: 1, printed: 1, text: nil, cleaned: nil}]
      })

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})
    {:ok, view, html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    refute has_element?(view, "a", "Review")
    # Extraction cost can't be estimated before extraction — show "—", not $0.0000.
    assert html =~ "est. —"
  end

  test "Review link shows once extracted with a low-confidence page", %{conn: conn} do
    admin = admin!("prep_review_admin")
    game = game_fixture(%{name: "Reviewable Prep"})

    {:ok, _doc} =
      RuleMaven.Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        pdf_path: "uploads/rulebooks/x.pdf",
        full_text: "text",
        # Extracted, but one page is below the confidence floor — review is now
        # actionable (:pending), so the Review link should appear.
        pages: [%{index: 0, sheet: 1, printed: 1, text: "text", cleaned: nil, confidence: 0.2}]
      })

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})
    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    assert has_element?(view, "a", "Review")
  end

  test "reset button is disabled with help text once questions exist", %{conn: conn} do
    admin = admin!("prep_noreset_admin")
    game = game_fixture(%{name: "Locked Game", bgg_id: 3344})
    with_doc(game)

    {:ok, _} =
      RuleMaven.Games.log_question(%{game_id: game.id, question: "Q?", answer: "A."})

    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})
    {:ok, view, html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    assert html =~ "unpublish instead of resetting."
    refute has_element?(view, "button[phx-click=\"reset_all\"]")
    assert has_element?(view, "button[disabled]", "Reset all")
  end
end
