defmodule RuleMavenWeb.CuratorLiveTest do
  @moduledoc """
  /curator page: stats, next-badge progress, settled-vote history, and the
  visit consuming pending settlement notices (curator_seen_at advances).
  """

  use RuleMavenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.Curation
  alias RuleMaven.Repo
  alias RuleMaven.Users

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix) do
    {:ok, user} =
      Users.create_user(%{
        username: "#{prefix}_user",
        email: "#{prefix}_user@test.com",
        password: "password1234"
      })

    user
  end

  defp settled_upvote(game, author, voter, question) do
    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        question: question,
        answer: "An answer.",
        user_id: author.id,
        pooled: true
      })

    Games.set_community_vote(q.id, voter.id, "up")
    {:ok, {1, 0}} = Curation.settle_votes(q, :confirmed)
    q
  end

  test "renders stats, next badge, and settled history", %{conn: conn} do
    game = game_fixture()
    author = create_user("author")
    voter = create_user("voter")

    settled_upvote(game, author, voter, "How does scoring work?")

    {:ok, _view, html} = conn |> login(voter) |> live(~p"/curator")

    assert html =~ "Curator"
    assert html =~ "curator points"
    # 1 correct settle → next badge is Curator at 1/10.
    assert html =~ "Next:"
    assert html =~ "1 / 10"
    # History shows the settled question and its game.
    assert html =~ "How does scoring work?"
    assert html =~ game.name
  end

  test "visiting consumes pending settlement notices", %{conn: conn} do
    game = game_fixture()
    author = create_user("author2")
    voter = create_user("voter2")

    settled_upvote(game, author, voter, "Does this settle?")
    assert Curation.unseen_correct_count(Repo.reload!(voter)) == 1

    {:ok, _view, _html} = conn |> login(voter) |> live(~p"/curator")

    assert Curation.unseen_correct_count(Repo.reload!(voter)) == 0
  end

  test "empty state renders for a user with no settled votes", %{conn: conn} do
    user = create_user("fresh")

    {:ok, _view, html} = conn |> login(user) |> live(~p"/curator")

    assert html =~ "Nothing settled yet"
    assert html =~ "No badges yet"
  end
end
