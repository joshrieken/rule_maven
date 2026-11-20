defmodule RuleMavenWeb.GameLive.CoverageIncentivesTest do
  use RuleMaven.DataCase, async: true

  import RuleMaven.GamesFixtures
  import Ecto.Query
  alias RuleMaven.Coverage
  alias RuleMaven.Coverage.UserPageCoverage
  alias RuleMaven.Games.Document
  alias RuleMaven.Repo

  defp published_doc(game) do
    {:ok, doc} =
      %Document{game_id: game.id}
      |> Document.changeset(%{
        label: "Rulebook",
        status: "published",
        page_count: 10
      })
      |> Repo.insert()

    doc
  end

  defp make_user do
    {:ok, user} =
      RuleMaven.Users.create_user(%{
        username: "inc_user_#{System.unique_integer([:positive])}",
        email: "inc_user_#{System.unique_integer([:positive])}@test.com",
        password: "password1234"
      })

    user
  end

  test "grounded assistant citations stamp the viewer's personal coverage" do
    game = game_fixture()
    doc = published_doc(game)
    user = make_user()

    # Mirror what the show.ex helper extracts: citations from grounded
    # assistant messages in @conversation.
    conversation = [
      %{role: :user, content: "q"},
      %{role: :assistant, citations: [%{"document_id" => doc.id, "page" => 5}]}
    ]

    citations =
      conversation
      |> Enum.filter(&(Map.get(&1, :role) == :assistant))
      |> Enum.flat_map(&(Map.get(&1, :citations) || []))

    assert {:ok, 1} = Coverage.record_personal(user.id, citations)
    assert Repo.aggregate(from(u in UserPageCoverage, where: u.user_id == ^user.id), :count) == 1
  end
end
