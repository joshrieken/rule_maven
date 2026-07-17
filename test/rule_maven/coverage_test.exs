defmodule RuleMaven.CoverageTest do
  use RuleMaven.DataCase, async: true

  import Ecto.Query
  import RuleMaven.GamesFixtures

  alias RuleMaven.Coverage
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

  describe "resolve_document_ids/2" do
    test "stamps document_id case-insensitive label match over games" do
      game = game_fixture()

      {:ok, doc} =
        %RuleMaven.Games.Document{}
        |> RuleMaven.Games.Document.changeset(%{
          label: "Base Rulebook",
          game_id: game.id,
          page_count: 12,
          status: "published"
        })
        |> Repo.insert()

      citations = [%{"quote" => "q", "page" => 4, "source" => "base rulebook"}]
      [stamped] = Coverage.resolve_document_ids(citations, [game.id])

      assert stamped["document_id"] == doc.id
    end

    test "leaves document_id absent when label does not resolve" do
      game = game_fixture()
      citations = [%{"quote" => "q", "page" => 4, "source" => "unknown source"}]
      [stamped] = Coverage.resolve_document_ids(citations, [game.id])

      refute Map.has_key?(stamped, "document_id")
    end
  end

  describe "record_citations/1" do
    test "upserts distinct (document_id, page) and is idempotent, clamped to page_count" do
      game = game_fixture()

      {:ok, doc} =
        %RuleMaven.Games.Document{}
        |> RuleMaven.Games.Document.changeset(%{
          label: "Rulebook",
          game_id: game.id,
          page_count: 8,
          status: "published"
        })
        |> Repo.insert()

      {:ok, user} =
        RuleMaven.Users.create_user(%{
          username: "coverage_user_#{System.unique_integer([:positive])}",
          email: "coverage_user_#{System.unique_integer([:positive])}@test.com",
          password: "password1234"
        })

      {:ok, ql} =
        RuleMaven.Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "Test question?",
          answer: "Test answer."
        })

      ql = %{
        ql
        | citations: [
            %{"page" => 3, "document_id" => doc.id},
            # dup page
            %{"page" => 3, "document_id" => doc.id},
            # beyond page_count -> skipped
            %{"page" => 99, "document_id" => doc.id},
            # no doc -> skipped
            %{"page" => 5, "document_id" => nil}
          ]
      }

      assert {:ok, 1} = Coverage.record_citations(ql)
      assert {:ok, 0} = Coverage.record_citations(ql)

      assert Repo.aggregate(
               from(p in PageCoverage, where: p.document_id == ^doc.id),
               :count
             ) == 1
    end
  end
end
