defmodule RuleMaven.CoveragePersonalTest do
  use RuleMaven.DataCase, async: true

  import Ecto.Query
  import RuleMaven.GamesFixtures

  alias RuleMaven.Coverage
  alias RuleMaven.Coverage.UserPageCoverage
  alias RuleMaven.Repo

  # Mirror the doc/user setup style already in test/rule_maven/coverage_test.exs.
  defp published_doc(game, attrs \\ %{}) do
    {:ok, doc} =
      %RuleMaven.Games.Document{}
      |> RuleMaven.Games.Document.changeset(
        Map.merge(
          %{label: "Rulebook", game_id: game.id, page_count: 10, status: "published"},
          attrs
        )
      )
      |> Repo.insert()

    doc
  end

  defp make_user do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "cov_user_#{System.unique_integer([:positive])}",
        email: "cov_user_#{System.unique_integer([:positive])}@test.com",
        password: "password1234"
      })

    user
  end

  test "user page coverage enforces (user_id, document_id, page) uniqueness" do
    game = game_fixture()
    doc = published_doc(game)
    user = make_user()

    Repo.insert!(%UserPageCoverage{user_id: user.id, document_id: doc.id, page: 3})

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%UserPageCoverage{user_id: user.id, document_id: doc.id, page: 3})
    end
  end

  describe "record_personal/2" do
    test "upserts distinct pages for a user, idempotent, clamps, skips unknown doc" do
      game = game_fixture()
      doc = published_doc(game, %{page_count: 8})
      user = make_user()

      citations = [
        %{"page" => 3, "document_id" => doc.id},
        # dup
        %{"page" => 3, "document_id" => doc.id},
        # beyond page_count -> skip
        %{"page" => 99, "document_id" => doc.id},
        # unknown doc -> skip (no FK crash)
        %{"page" => 5, "document_id" => 999_999},
        # no doc -> skip
        %{"page" => 4, "document_id" => nil}
      ]

      # page 3 only
      assert {:ok, 1} = Coverage.record_personal(user.id, citations)
      # idempotent
      assert {:ok, 0} = Coverage.record_personal(user.id, citations)

      assert Repo.aggregate(
               from(u in UserPageCoverage, where: u.user_id == ^user.id),
               :count
             ) == 1
    end

    test "nil user_id records nothing" do
      game = game_fixture()
      doc = published_doc(game)
      assert {:ok, 0} = Coverage.record_personal(nil, [%{"page" => 1, "document_id" => doc.id}])
    end
  end

  describe "personal_for_game/2" do
    test "personal pct uses the same denominator as for_game" do
      game = game_fixture()
      doc = published_doc(game, %{page_count: 4})
      user = make_user()

      Repo.insert!(%UserPageCoverage{user_id: user.id, document_id: doc.id, page: 1})
      Repo.insert!(%UserPageCoverage{user_id: user.id, document_id: doc.id, page: 2})

      assert %{total: 4, covered: 2, pct: pct} = Coverage.personal_for_game(user.id, game.id)
      assert_in_delta pct, 0.5, 0.001
      # denominator parity: community for_game over the same game reports total 4
      assert Coverage.for_game(game.id).total == 4
    end

    test "nil page_count -> nil pct" do
      game = game_fixture()
      _doc = published_doc(game, %{page_count: nil})
      user = make_user()
      assert %{pct: nil} = Coverage.personal_for_game(user.id, game.id)
    end
  end

  describe "title_for/2" do
    setup do
      game = game_fixture(%{name: "Catan"})
      doc = published_doc(game, %{page_count: 4})
      user = make_user()
      %{game: game, doc: doc, user: user}
    end

    test "below 25% has no title", %{game: g, user: u} do
      assert %{tier: nil, label: nil} = Coverage.title_for(u.id, g.id)
    end

    test "25% -> Student, label carries game name", %{game: g, doc: d, user: u} do
      Repo.insert!(%UserPageCoverage{user_id: u.id, document_id: d.id, page: 1})
      assert %{tier: :student, label: "Catan Student", pct: pct} = Coverage.title_for(u.id, g.id)
      assert_in_delta pct, 0.25, 0.001
    end

    test "50% -> Scholar, 75% -> Expert", %{game: g, doc: d, user: u} do
      Enum.each(1..2, &Repo.insert!(%UserPageCoverage{user_id: u.id, document_id: d.id, page: &1}))
      assert %{tier: :scholar} = Coverage.title_for(u.id, g.id)
      Repo.insert!(%UserPageCoverage{user_id: u.id, document_id: d.id, page: 3})
      assert %{tier: :expert} = Coverage.title_for(u.id, g.id)
    end

    test "Sage when personal set covers the whole community-covered set", %{game: g, doc: d, user: u} do
      Enum.each(1..2, &Repo.insert!(%RuleMaven.Coverage.PageCoverage{document_id: d.id, page: &1}))
      Enum.each(1..2, &Repo.insert!(%UserPageCoverage{user_id: u.id, document_id: d.id, page: &1}))
      assert %{tier: :sage} = Coverage.title_for(u.id, g.id)
    end

    test "empty community set is not Sage", %{game: g, doc: d, user: u} do
      Enum.each(1..3, &Repo.insert!(%UserPageCoverage{user_id: u.id, document_id: d.id, page: &1}))
      assert %{tier: :expert} = Coverage.title_for(u.id, g.id)
    end
  end

  describe "gaps_enriched/1" do
    test "returns uncovered pages with a snippet from chunk text" do
      game = game_fixture()
      doc = published_doc(game, %{page_count: 3})
      Repo.insert!(%RuleMaven.Coverage.PageCoverage{document_id: doc.id, page: 2})

      Repo.insert!(%RuleMaven.Games.Chunk{
        document_id: doc.id,
        page_number: 1,
        chunk_index: 0,
        content: "Setup\nPlace the board in the center.",
        section_label: "Setup"
      })

      Repo.insert!(%RuleMaven.Games.Chunk{
        document_id: doc.id,
        page_number: 3,
        chunk_index: 0,
        content: "Winning the game\nFirst to 10 points wins.",
        section_label: nil
      })

      gaps = Coverage.gaps_enriched(game.id)

      assert [%{page: 1, label: "Setup", snippet: "Setup"}, %{page: 3, snippet: "Winning the game"}] =
               Enum.map(gaps, &Map.take(&1, [:page, :label, :snippet]))
    end
  end

  describe "contribution_credit/2" do
    test "counts only this user's first-covered pages in the game" do
      game = game_fixture()
      doc = published_doc(game)
      u1 = make_user()
      u2 = make_user()

      Repo.insert!(%RuleMaven.Coverage.PageCoverage{
        document_id: doc.id,
        page: 1,
        first_covered_by_user_id: u1.id
      })

      Repo.insert!(%RuleMaven.Coverage.PageCoverage{
        document_id: doc.id,
        page: 2,
        first_covered_by_user_id: u1.id
      })

      Repo.insert!(%RuleMaven.Coverage.PageCoverage{
        document_id: doc.id,
        page: 3,
        first_covered_by_user_id: u2.id
      })

      assert Coverage.contribution_credit(u1.id, game.id) == 2
      assert Coverage.contribution_credit(u2.id, game.id) == 1
    end
  end
end
