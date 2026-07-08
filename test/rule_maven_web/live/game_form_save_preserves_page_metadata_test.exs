defmodule RuleMavenWeb.GameFormSavePreservesPageMetadataTest do
  @moduledoc """
  Regression test for a bug where saving the edit page (e.g. just renaming a
  rulebook) wiped every extraction-metadata field off the document's pages:
  the save handler rebuilt each page as only
  `%{index, sheet, printed, text, cleaned}`, so `lane`, `confidence`,
  `source`, the gate decision-log fields and `cleanup_defects` were all
  dropped by the embed replace.

  Losing `lane`/`confidence` made `Readiness.doc_cleaned?/1` stop recognizing
  pages the auto cleanup had deliberately skipped (confident vision-lane
  pages keep `cleaned: nil`), so a fully prepared game regressed to a
  permanently Pending cleanup step — and a Pending embed step with it —
  after a label-only save.
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

  test "label-only save keeps page extraction metadata and cleanup completeness", %{conn: conn} do
    user = admin_user("page_meta_rename_user")
    game = game_fixture(%{name: "Metadata Game", image_url: "http://example.com/box.jpg"})

    # One cleaned ensemble page + one confident vision page the auto cleanup
    # skipped (cleaned: nil) — the exact shape that regressed to Pending.
    pages = [
      %{
        index: 0,
        sheet: 1,
        printed: 1,
        text: "raw page one",
        cleaned: "clean page one",
        confidence: 0.9,
        lane: "ensemble",
        source: "ensemble",
        gate_agreement: 0.97,
        gate_coverage: 0.99,
        escalated: false,
        critic_rounds: 1,
        residual_defects: 0,
        cleanup_defects: []
      },
      %{
        index: 1,
        sheet: 2,
        printed: 2,
        text: "raw page two",
        cleaned: nil,
        confidence: 0.8,
        lane: "vision",
        source: "vision",
        gate_agreement: 0.95,
        gate_coverage: 0.98,
        escalated: false,
        critic_rounds: 0,
        residual_defects: 0
      }
    ]

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Old Name",
        full_text: Games.rebuild_full_text(pages),
        pages: pages,
        kind: "rulebook",
        status: "published"
      })

    assert RuleMaven.Readiness.step_complete?(:cleanup, game, [doc])

    conn = login(conn, user)
    {:ok, view, _html} = live(conn, "/games/#{RuleMaven.Hashid.encode(game.id)}/edit")

    view
    |> form("#game-form", %{
      "game" => %{"name" => game.name},
      "label_0" => "New Name"
    })
    |> render_submit()

    saved = Games.get_document!(doc.id)
    assert saved.label == "New Name"

    [p1, p2] = saved.pages
    assert p1.lane == "ensemble"
    assert p1.confidence == 0.9
    assert p1.cleaned == "clean page one"
    assert p1.gate_agreement == 0.97
    assert p1.critic_rounds == 1
    assert p1.cleanup_defects == []
    assert p2.lane == "vision"
    assert p2.confidence == 0.8
    assert p2.source == "vision"
    assert is_nil(p2.cleaned)

    # The skipped-but-confident vision page must still count as clean.
    assert RuleMaven.Readiness.step_complete?(:cleanup, game, [saved])
  end
end
