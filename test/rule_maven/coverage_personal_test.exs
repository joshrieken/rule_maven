defmodule RuleMaven.CoveragePersonalTest do
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures

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
end
