defmodule RuleMavenWeb.StandingLiveTest do
  @moduledoc """
  /standing page: curator stats, next-badge progress, settled-vote history,
  contributor reputation, and the visit consuming pending settlement notices
  (curator_seen_at advances).
  """

  use RuleMavenWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.Curation
  alias RuleMaven.Repo
  alias RuleMaven.Users

  # set_question_visibility enqueues SettleVotesWorker, so Oban must be
  # supervised here (same pattern as moderation_test.exs).
  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

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
        pooled: true,
        browsable: true
      })

    Games.set_community_vote(q.id, voter.id, "up")
    {:ok, {1, 0}} = Curation.settle_votes(q, :confirmed)
    q
  end

  test "renders curator stats, next badge, and settled history", %{conn: conn} do
    game = game_fixture()
    author = create_user("author")
    voter = create_user("voter")

    settled_upvote(game, author, voter, "How does scoring work?")

    {:ok, _view, html} = conn |> login(voter) |> live(~p"/standing")

    assert html =~ "Community standing"
    assert html =~ "curator points"
    # 1 correct settle → next badge is Curator at 1/10.
    assert html =~ "Next:"
    assert html =~ "1 / 10"
    # History shows the settled question and its game.
    assert html =~ "How does scoring work?"
    assert html =~ game.name
  end

  test "renders contributor reputation and promoted count", %{conn: conn} do
    game = game_fixture()
    asker = create_user("asker")

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        question: "Promoted Q?",
        answer: "A.",
        user_id: asker.id,
        pooled: true,
        browsable: true
      })

    q |> Ecto.Changeset.change(promoted: true, pooled: true) |> Repo.update!()
    RuleMaven.Games.Trust.recompute_reputation(asker.id)

    {:ok, _view, html} = conn |> login(asker) |> live(~p"/standing")

    assert html =~ "Contributor"
    assert html =~ "reputation"
    assert html =~ "answers promoted to community"
    # Promotion grants the reputation bonus (5) and counts one promoted row.
    stats = Curation.contributor_stats(asker.id)
    assert stats.promoted == 1
    assert stats.reputation >= 5
  end

  test "visiting consumes pending settlement notices", %{conn: conn} do
    game = game_fixture()
    author = create_user("author2")
    voter = create_user("voter2")

    settled_upvote(game, author, voter, "Does this settle?")
    assert Curation.unseen_correct_count(Repo.reload!(voter)) == 1

    {:ok, _view, _html} = conn |> login(voter) |> live(~p"/standing")

    assert Curation.unseen_correct_count(Repo.reload!(voter)) == 0
  end

  test "empty state renders for a user with no settled votes", %{conn: conn} do
    user = create_user("fresh")

    {:ok, _view, html} = conn |> login(user) |> live(~p"/standing")

    assert html =~ "Nothing settled yet"
    assert html =~ "No badges yet"
  end
end
