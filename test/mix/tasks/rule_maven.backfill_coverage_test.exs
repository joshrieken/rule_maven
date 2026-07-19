defmodule Mix.Tasks.RuleMaven.BackfillCoverageTest do
  use RuleMaven.DataCase, async: false

  import RuleMaven.GamesFixtures

  alias RuleMaven.Coverage
  alias RuleMaven.Repo

  test "seeds coverage from existing citations and is idempotent" do
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

    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "backfill_user_#{System.unique_integer([:positive])}",
        email: "backfill_user_#{System.unique_integer([:positive])}@test.com",
        password: "password1234"
      })

    {:ok, _ql} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How does setup work?",
        answer: "See page 6.",
        citations: [%{"quote" => "q", "page" => 6, "source" => "Rulebook"}]
      })

    Mix.Tasks.RuleMaven.BackfillCoverage.run([])
    assert Coverage.for_document(doc.id).covered == 1

    Mix.Tasks.RuleMaven.BackfillCoverage.run([])
    assert Coverage.for_document(doc.id).covered == 1
  end

  test "ignores rows with no citations" do
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

    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "backfill_user2_#{System.unique_integer([:positive])}",
        email: "backfill_user2_#{System.unique_integer([:positive])}@test.com",
        password: "password1234"
      })

    {:ok, _ql} =
      RuleMaven.Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How does setup work?",
        answer: "See page 6."
      })

    Mix.Tasks.RuleMaven.BackfillCoverage.run([])
    assert Coverage.for_document(doc.id).covered == 0
  end
end
