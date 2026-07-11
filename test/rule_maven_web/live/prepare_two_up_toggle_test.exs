defmodule RuleMavenWeb.PrepareTwoUpToggleTest do
  @moduledoc """
  The "2 pages per sheet" toggle on the Prepare page's Source step: flips
  `Document.two_up` (which the next extraction reads to split each sheet into
  left/right logical pages) without touching the document's text or pipeline
  state, and is scoped to the current game.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp admin_user(name) do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "password1234",
        role: "admin"
      })

    user
  end

  defp setup_game_with_pdf_doc(label) do
    game =
      game_fixture(%{
        name: "Prepare TwoUp Game #{label}",
        bgg_id: System.unique_integer([:positive])
      })

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: label,
        full_text: nil,
        pages: [],
        kind: "rulebook",
        pdf_path: "uploads/rulebooks/#{label}.pdf"
      })

    {game, doc}
  end

  test "admin toggles two_up on and off", %{conn: conn} do
    user = admin_user("prepare_two_up_admin")
    {game, doc} = setup_game_with_pdf_doc("spread-scan")

    conn = login(conn, user)
    {:ok, view, html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    assert html =~ "2 pages per sheet"
    refute Games.get_document!(doc.id).two_up

    view |> element("input[phx-click='toggle_two_up']") |> render_click()
    assert Games.get_document!(doc.id).two_up

    view |> element("input[phx-click='toggle_two_up']") |> render_click()
    refute Games.get_document!(doc.id).two_up
  end

  test "toggle leaves text and pipeline state alone", %{conn: conn} do
    user = admin_user("prepare_two_up_state")
    {game, doc} = setup_game_with_pdf_doc("state-check")

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    view |> element("input[phx-click='toggle_two_up']") |> render_click()

    updated = Games.get_document!(doc.id)
    assert updated.two_up
    assert updated.full_text == doc.full_text
    assert updated.extracted_at == doc.extracted_at
  end

  test "cannot toggle another game's document", %{conn: conn} do
    user = admin_user("prepare_two_up_cross")
    {game, _doc} = setup_game_with_pdf_doc("mine")
    {_other_game, other_doc} = setup_game_with_pdf_doc("not-mine")

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    render_click(view, "toggle_two_up", %{"id" => other_doc.id})

    refute Games.get_document!(other_doc.id).two_up
  end
end
