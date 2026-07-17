defmodule RuleMaven.CoverageTest do
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures

  alias RuleMaven.Coverage.PageCoverage
  alias RuleMaven.Repo

  test "page coverage row inserts and enforces (document_id, page) uniqueness" do
    game = game_fixture()

    {:ok, doc} =
      %RuleMaven.Games.Document{}
      |> RuleMaven.Games.Document.changeset(%{
        label: "Rulebook",
        game_id: game.id,
        page_count: 10,
        status: "published"
      })
      |> Repo.insert()

    {:ok, _} = Repo.insert(%PageCoverage{document_id: doc.id, page: 3})

    # A bare struct insert has no changeset declaring unique_constraint/3, so
    # the DB-level unique violation surfaces as a raised Ecto.ConstraintError
    # rather than {:error, changeset}. This still proves the index enforces
    # (document_id, page) uniqueness.
    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert(%PageCoverage{document_id: doc.id, page: 3})
    end
  end
end
