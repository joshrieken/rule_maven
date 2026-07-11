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

  test "the toggle row explains the split axis (visible without hover)", %{conn: conn} do
    user = admin_user("prepare_two_up_axis")
    {game, _doc} = setup_game_with_pdf_doc("axis-note")

    conn = login(conn, user)
    {:ok, _view, html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    # Persistent (not tooltip-only) so touch users see the left→right axis and
    # a narrow side-by-side spread stays discoverable even when the aspect hint
    # doesn't fire.
    assert html =~ "splits left→right"
  end

  @have_tools Enum.all?(~w(magick pdfinfo), &System.find_executable/1)

  @tag skip: not @have_tools
  test "enabling two_up on a portrait sheet warns about the left→right split", %{conn: conn} do
    user = admin_user("prepare_two_up_portrait")
    {game, doc} = setup_game_with_pdf_doc("portrait-book")

    # Stage a real portrait PDF at the document's pdf_path so portrait_sheet?
    # can read it.
    static = Application.app_dir(:rule_maven, "priv/static")
    dest = Path.join(static, doc.pdf_path)
    File.mkdir_p!(Path.dirname(dest))
    {_, 0} = System.cmd("magick", ["-size", "200x400", "canvas:white", dest])
    on_exit(fn -> File.rm(dest) end)

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    html = view |> element("input[phx-click='toggle_two_up']") |> render_click()

    assert Games.get_document!(doc.id).two_up
    assert html =~ "portrait"
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
