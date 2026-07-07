defmodule RuleMavenWeb.PrepareRenameDocumentTest do
  @moduledoc """
  Inline rulebook rename on the Prepare page: the Source step preview shows a
  pencil button per rulebook that swaps the name for a small form; submitting
  saves the new label without touching the document's text or pipeline state.
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

  defp setup_game_with_doc(label) do
    game =
      game_fixture(%{
        name: "Prepare Rename Game #{label}",
        bgg_id: System.unique_integer([:positive])
      })

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: label,
        full_text: nil,
        pages: [],
        kind: "rulebook"
      })

    {game, doc}
  end

  test "admin renames a rulebook inline", %{conn: conn} do
    user = admin_user("prepare_rename_admin")
    {game, doc} = setup_game_with_doc("Old Rulebook Name")

    conn = login(conn, user)
    {:ok, view, html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    assert html =~ "Old Rulebook Name"

    # Pencil opens the inline form pre-filled with the current name.
    html = view |> element("button[phx-value-id='#{doc.id}']", "✎") |> render_click()
    assert html =~ ~s(phx-submit="rename_document")
    assert html =~ "Old Rulebook Name"

    html =
      view
      |> form("form[phx-submit='rename_document']", %{
        "doc_id" => doc.id,
        "label" => "  New Rulebook Name  "
      })
      |> render_submit()

    assert Games.get_document!(doc.id).label == "New Rulebook Name"
    assert html =~ "New Rulebook Name"
    refute html =~ ~s(phx-submit="rename_document")
  end

  test "cancel closes the form without saving", %{conn: conn} do
    user = admin_user("prepare_rename_cancel")
    {game, doc} = setup_game_with_doc("Keep This Name")

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    view |> element("button[phx-value-id='#{doc.id}']", "✎") |> render_click()
    html = view |> element("button[phx-click='cancel_rename']") |> render_click()

    refute html =~ ~s(phx-submit="rename_document")
    assert Games.get_document!(doc.id).label == "Keep This Name"
  end

  test "blank name is rejected", %{conn: conn} do
    user = admin_user("prepare_rename_blank")
    {game, doc} = setup_game_with_doc("Non Blank Name")

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    view |> element("button[phx-value-id='#{doc.id}']", "✎") |> render_click()

    render_submit(view, "rename_document", %{"doc_id" => doc.id, "label" => "   "})

    assert Games.get_document!(doc.id).label == "Non Blank Name"
  end

  test "cannot rename another game's document", %{conn: conn} do
    user = admin_user("prepare_rename_cross")
    {game, _doc} = setup_game_with_doc("Mine")
    {_other_game, other_doc} = setup_game_with_doc("Not Mine")

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    render_submit(view, "rename_document", %{"doc_id" => other_doc.id, "label" => "Hijacked"})

    assert Games.get_document!(other_doc.id).label == "Not Mine"
  end
end
