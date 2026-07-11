defmodule RuleMaven.Workers.DirectPromotionWorkerTest do
  use RuleMaven.DataCase

  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.Repo
  alias RuleMaven.Users
  alias RuleMaven.Users.User
  alias RuleMaven.Workers.DirectPromotionWorker

  # Oban isn't supervised in test (config :rule_maven, Oban, testing: :manual),
  # but promote/1 now enqueues a SettleVotesWorker job via Oban.insert/1,
  # which needs a named, configured instance to insert against. Start a
  # queueless/pluginless one under the default name so the plain (unnamed)
  # insert call resolves for real. (Same pattern as
  # test/rule_maven/house_rules_test.exs.)
  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp user_fixture(name) do
    {:ok, u} =
      Users.create_user(%{username: name, email: "#{name}@test.com", password: "testpass1234"})

    u
  end

  # A voter eligible to count toward a promotion quorum: email confirmed.
  defp confirmed_user(name) do
    {:ok, u} = user_fixture(name) |> User.confirm_changeset() |> Repo.update()
    u
  end

  defp pooled_row(game, author, embedding) do
    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        user_id: author.id,
        question: "How does scoring work?",
        answer: "Score like so.",
        cited_passage: "p.3",
        citation_valid: true,
        visibility: "private",
        pooled: true
      })

    Repo.update_all(
      from(r in QuestionLog, where: r.id == ^q.id),
      set: [question_embedding: Pgvector.new(embedding)]
    )

    q
  end

  setup do
    RuleMaven.Settings.put("promotion_floor", "3.0")
    %{game: game_fixture(), author: user_fixture("author")}
  end

  test "promotes a pooled row that clears the floor with a quorum of eligible voters",
       %{game: game, author: author} do
    row = pooled_row(game, author, Enum.to_list(1..768))

    # Two confirmed, distinct, non-author upvotes + citation bonus = 3.0 >= floor.
    Games.set_community_vote(row.id, confirmed_user("v1").id, "up")
    Games.set_community_vote(row.id, confirmed_user("v2").id, "up")

    assert :ok == DirectPromotionWorker.perform(%Oban.Job{args: %{}})

    assert Repo.get(QuestionLog, row.id).visibility == "community"
    assert Repo.get(User, author.id).reputation > 0
  end

  test "does not promote without a voter quorum even above the floor",
       %{game: game, author: author} do
    row = pooled_row(game, author, Enum.to_list(1..768))

    # One high-rep confirmed voter can clear the floor alone, but quorum (2) is
    # not met, so it must stay private.
    {:ok, voter} =
      confirmed_user("solo") |> Ecto.Changeset.change(reputation: 50) |> Repo.update()

    Games.set_community_vote(row.id, voter.id, "up")

    assert Repo.get(QuestionLog, row.id).trust_score >= 3.0
    assert :ok == DirectPromotionWorker.perform(%Oban.Job{args: %{}})
    assert Repo.get(QuestionLog, row.id).visibility == "private"
  end

  test "unconfirmed voters do not count toward quorum",
       %{game: game, author: author} do
    row = pooled_row(game, author, Enum.to_list(1..768))

    # Two votes, but neither voter has confirmed their email → quorum unmet.
    Games.set_community_vote(row.id, user_fixture("u1").id, "up")
    Games.set_community_vote(row.id, user_fixture("u2").id, "up")

    assert :ok == DirectPromotionWorker.perform(%Oban.Job{args: %{}})
    assert Repo.get(QuestionLog, row.id).visibility == "private"
  end

  test "leaves a below-floor row private", %{game: game, author: author} do
    row = pooled_row(game, author, Enum.to_list(1..768))
    Games.set_community_vote(row.id, confirmed_user("v1").id, "up")

    assert :ok == DirectPromotionWorker.perform(%Oban.Job{args: %{}})
    assert Repo.get(QuestionLog, row.id).visibility == "private"
  end

  test "never promotes an unbrowsable row, even above the floor with full quorum",
       %{game: game, author: author} do
    row = pooled_row(game, author, Enum.to_list(1..768))

    Repo.update_all(
      from(r in QuestionLog, where: r.id == ^row.id),
      set: [browsable: false]
    )

    # Same conditions as the passing-promotion test above (two confirmed,
    # distinct, non-author upvotes clear the floor with quorum) — the ONLY
    # thing that should stop promotion here is browsable == false.
    Games.set_community_vote(row.id, confirmed_user("v1").id, "up")
    Games.set_community_vote(row.id, confirmed_user("v2").id, "up")

    assert Repo.get(QuestionLog, row.id).trust_score >= 3.0
    assert :ok == DirectPromotionWorker.perform(%Oban.Job{args: %{}})
    assert Repo.get(QuestionLog, row.id).visibility == "private"
  end
end
