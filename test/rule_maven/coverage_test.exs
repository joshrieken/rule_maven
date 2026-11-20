defmodule RuleMaven.CoverageTest do
  use RuleMaven.DataCase, async: true

  import Ecto.Query
  import RuleMaven.GamesFixtures

  alias RuleMaven.Coverage
  alias RuleMaven.Coverage.PageCoverage
  alias RuleMaven.Games.Document
  alias RuleMaven.Repo

  test "page coverage row inserts and enforces (document_id, page) uniqueness" do
    game = game_fixture()

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
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
        %Document{}
        |> Document.changeset(%{
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
        %Document{}
        |> Document.changeset(%{
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

    test "citation for a non-existent document is skipped, not a raise" do
      game = game_fixture()

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
            %{"page" => 3, "document_id" => 999_999}
          ]
      }

      assert {:ok, 0} = Coverage.record_citations(ql)
    end
  end

  describe "reads" do
    test "for_document computes pct, nil page_count -> nil pct" do
      game = game_fixture()

      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          label: "Rulebook",
          game_id: game.id,
          page_count: 4,
          status: "published"
        })
        |> Repo.insert()

      Repo.insert!(%PageCoverage{document_id: doc.id, page: 1})
      Repo.insert!(%PageCoverage{document_id: doc.id, page: 2})

      assert %{page_count: 4, covered: 2, pct: pct} = Coverage.for_document(doc.id)
      assert_in_delta pct, 0.5, 0.001

      {:ok, nild} =
        %Document{}
        |> Document.changeset(%{
          label: "Appendix",
          game_id: game.id,
          page_count: nil,
          status: "published"
        })
        |> Repo.insert()

      assert %{pct: nil} = Coverage.for_document(nild.id)
    end

    test "for_game rolls up published docs only, across expansions" do
      game = game_fixture()
      expansion = game_fixture(%{bgg_id: 4200 + System.unique_integer([:positive])})
      :ok = RuleMaven.Games.link_expansion(expansion.id, game.id)

      {:ok, pub} =
        %Document{}
        |> Document.changeset(%{
          label: "Rulebook",
          game_id: game.id,
          page_count: 4,
          status: "published"
        })
        |> Repo.insert()

      Repo.insert!(%PageCoverage{document_id: pub.id, page: 1})

      {:ok, pending} =
        %Document{}
        |> Document.changeset(%{
          label: "Draft",
          game_id: game.id,
          page_count: 10,
          status: "pending_review"
        })
        |> Repo.insert()

      Repo.insert!(%PageCoverage{document_id: pending.id, page: 1})

      {:ok, exp_doc} =
        %Document{}
        |> Document.changeset(%{
          label: "Expansion Rulebook",
          game_id: expansion.id,
          page_count: 6,
          status: "published"
        })
        |> Repo.insert()

      Repo.insert!(%PageCoverage{document_id: exp_doc.id, page: 1})
      Repo.insert!(%PageCoverage{document_id: exp_doc.id, page: 2})

      roll = Coverage.for_game(game.id)

      assert roll.total == 10
      assert roll.covered == 3
      assert_in_delta roll.pct, 0.3, 0.001

      source_ids = Enum.map(roll.sources, & &1.document_id) |> Enum.sort()
      assert source_ids == Enum.sort([pub.id, exp_doc.id])
      refute pending.id in source_ids
    end

    test "gaps returns sorted uncovered page numbers, [] when page_count nil" do
      game = game_fixture()

      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          label: "Rulebook",
          game_id: game.id,
          page_count: 3,
          status: "published"
        })
        |> Repo.insert()

      Repo.insert!(%PageCoverage{document_id: doc.id, page: 2})

      assert Coverage.gaps(doc.id) == [1, 3]

      {:ok, nild} =
        %Document{}
        |> Document.changeset(%{
          label: "Appendix",
          game_id: game.id,
          page_count: nil,
          status: "published"
        })
        |> Repo.insert()

      assert Coverage.gaps(nild.id) == []
    end

    test "for_game pct never exceeds 1.0 when a nil page_count doc has coverage rows" do
      game = game_fixture()

      {:ok, pub} =
        %Document{}
        |> Document.changeset(%{
          label: "Rulebook",
          game_id: game.id,
          page_count: 4,
          status: "published"
        })
        |> Repo.insert()

      Repo.insert!(%PageCoverage{document_id: pub.id, page: 1})
      Repo.insert!(%PageCoverage{document_id: pub.id, page: 2})

      {:ok, nild} =
        %Document{}
        |> Document.changeset(%{
          label: "Appendix",
          game_id: game.id,
          page_count: nil,
          status: "published"
        })
        |> Repo.insert()

      Repo.insert!(%PageCoverage{document_id: nild.id, page: 1})
      Repo.insert!(%PageCoverage{document_id: nild.id, page: 2})
      Repo.insert!(%PageCoverage{document_id: nild.id, page: 3})

      roll = Coverage.for_game(game.id)

      assert roll.total == 4
      assert roll.covered == 2
      assert_in_delta roll.pct, 0.5, 0.001
      assert roll.pct <= 1.0
    end
  end
end
