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
end
