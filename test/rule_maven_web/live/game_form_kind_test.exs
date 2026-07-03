defmodule RuleMavenWeb.GameFormKindTest do
  @moduledoc """
  Task 5 review gap: no test exercised the `set_kind` LiveView wiring (the
  `is_core` toggle was replaced with a `kind` select in form.ex). Covers:

  - The select and badge render the document's current kind via
    `Document.kind_label/1`.
  - Changing the select fires `set_kind`, which persists the new kind on the
    already-saved document (`Games.update_document/2`).
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.Document

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

  defp game_with_document(kind) do
    # image_url set so the edit form isn't gated behind the BGG-sync prompt
    # (same convention as game_form_error_handling_test.exs).
    game = game_fixture(%{name: "Kind Game", image_url: "http://example.com/box.jpg"})

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Core Rules",
        full_text: "Some rules text.",
        kind: kind
      })

    {game, doc}
  end

  test "select and badge render the document's current kind", %{conn: conn} do
    user = admin_user("kind_render_user")
    {game, _doc} = game_with_document("faq")

    conn = login(conn, user)
    {:ok, _view, html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/edit")

    assert html =~ Document.kind_label("faq")
    assert html =~ ~s(value="faq" selected)
  end

  test "selecting a new kind persists it on the saved document", %{conn: conn} do
    user = admin_user("kind_persist_user")
    {game, doc} = game_with_document("rulebook")

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/edit")

    # source_entry/2 assigns entry.id = its index in the (single-source) list.
    html =
      view
      |> element(~s(select[phx-value-id="0"]))
      |> render_change(%{"id" => "0", "kind" => "errata"})

    assert html =~ Document.kind_label("errata")
    assert Games.get_document!(doc.id).kind == "errata"
  end
end
