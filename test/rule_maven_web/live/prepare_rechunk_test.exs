defmodule RuleMavenWeb.PrepareRechunkTest do
  # An embedded rulebook can be re-chunked from Prepare so it picks up chunking
  # changes (e.g. scenario headings carried onto continuation pages).
  use RuleMavenWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games.{Chunk, Document}
  alias RuleMaven.Repo

  test "admin re-chunks an embedded rulebook", %{conn: conn} do
    {:ok, admin} =
      RuleMaven.Users.create_user(%{
        username: "rechunk_#{System.unique_integer([:positive])}",
        email: "rechunk_#{System.unique_integer([:positive])}@test.com",
        password: "password1234",
        role: "admin"
      })

    game =
      game_fixture(%{
        name: "Rechunk #{System.unique_integer([:positive])}",
        bgg_id: System.unique_integer([:positive]),
        bgg_data: "<items/>",
        min_players: 2
      })

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        game_id: game.id,
        label: "Rules",
        full_text: "x",
        status: "cleaned",
        pages: [
          %{index: 0, sheet: 1, printed: 38, text: "QUEST 0: TUTORIAL\nsetup"},
          %{index: 1, sheet: 2, printed: 39, text: "The green Spawn Zone is inactive."}
        ]
      })
      |> Repo.insert()

    # An old-style, fully embedded chunk set (no heading carry).
    Repo.insert!(%Chunk{
      document_id: doc.id,
      chunk_index: 0,
      content: "[Page 39]\nThe green Spawn Zone is inactive.",
      page_number: 39,
      embedding: List.duplicate(0.0, 768)
    })

    {:ok, view, _html} =
      conn
      |> Plug.Test.init_test_session(%{"user_id" => admin.id})
      |> live("/games/#{RuleMaven.Hashid.encode(game.id)}/prepare")

    assert has_element?(view, ~s(button[phx-click="rechunk"]))
    render_click(view, "rechunk", %{})

    contents =
      Repo.all(from c in Chunk, where: c.document_id == ^doc.id, select: c.content)

    assert Enum.any?(contents, &(&1 =~ "(Continues: QUEST 0: TUTORIAL)"))
  end
end
