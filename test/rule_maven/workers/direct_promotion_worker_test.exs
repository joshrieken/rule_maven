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
        promoted: false,
        pooled: true,
        browsable: true
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

    assert Repo.get(QuestionLog, row.id).promoted
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
    refute Repo.get(QuestionLog, row.id).promoted
  end

  test "unconfirmed voters do not count toward quorum",
       %{game: game, author: author} do
    row = pooled_row(game, author, Enum.to_list(1..768))

    # Two votes, but neither voter has confirmed their email → quorum unmet.
    Games.set_community_vote(row.id, user_fixture("u1").id, "up")
    Games.set_community_vote(row.id, user_fixture("u2").id, "up")

    assert :ok == DirectPromotionWorker.perform(%Oban.Job{args: %{}})
    refute Repo.get(QuestionLog, row.id).promoted
  end

  test "leaves a below-floor row private", %{game: game, author: author} do
    row = pooled_row(game, author, Enum.to_list(1..768))
    Games.set_community_vote(row.id, confirmed_user("v1").id, "up")

    assert :ok == DirectPromotionWorker.perform(%Oban.Job{args: %{}})
    refute Repo.get(QuestionLog, row.id).promoted
  end

  test "never promotes an unbrowsable row, even above the floor with full quorum",
       %{game: game, author: author} do
    row = pooled_row(game, author, Enum.to_list(1..768))

    # Same conditions as the passing-promotion test above (two confirmed,
    # distinct, non-author upvotes clear the floor with quorum) — the ONLY
    # thing that should stop promotion here is browsable == false.
    #
    # The votes are cast BEFORE the row is made unbrowsable because
    # `Games.votable?/1` now refuses an unbrowsable row outright — voting first
    # is the only way to build a genuine above-floor, quorum-backed row and so
    # leave `browsable` as the single variable under test. That refusal is the
    # first line of defence; this test pins the second (the worker's own query),
    # so a row that reaches high trust by any route still cannot be promoted.
    Games.set_community_vote(row.id, confirmed_user("v1").id, "up")
    Games.set_community_vote(row.id, confirmed_user("v2").id, "up")

    assert Repo.get(QuestionLog, row.id).trust_score >= 3.0

    Repo.update_all(
      from(r in QuestionLog, where: r.id == ^row.id),
      set: [browsable: false]
    )

    assert :ok == DirectPromotionWorker.perform(%Oban.Job{args: %{}})
    refute Repo.get(QuestionLog, row.id).promoted
  end

  test "never promotes a row staled by a rulebook change, even above the floor",
       %{game: game, author: author} do
    row = pooled_row(game, author, Enum.to_list(1..768))
    Games.set_community_vote(row.id, confirmed_user("v1").id, "up")
    Games.set_community_vote(row.id, confirmed_user("v2").id, "up")
    assert Repo.get(QuestionLog, row.id).trust_score >= 3.0

    # A rulebook edit staled this answer; its citations may no longer hold, so
    # it must not be promoted into the shared pool until re-grounded.
    Repo.update_all(from(r in QuestionLog, where: r.id == ^row.id), set: [stale: true])

    assert :ok == DirectPromotionWorker.perform(%Oban.Job{args: %{}})
    refute Repo.get(QuestionLog, row.id).promoted
  end

  test "does not cluster facet-incompatible rows that share an embedding",
       %{game: game, author: author} do
    # Two promote-eligible rows with an IDENTICAL embedding but opposite-verdict
    # questions (before vs after). Clustering would merge them and let one
    # representative stand in for both — inheriting cluster trust across a facet
    # flip and suppressing the other's independent promotion.
    before_row = pooled_row(game, author, Enum.to_list(1..768))
    after_row = pooled_row(game, user_fixture("author2"), Enum.to_list(1..768))

    Repo.update_all(from(r in QuestionLog, where: r.id == ^before_row.id),
      set: [question: "Can a player trade before rolling?"]
    )

    Repo.update_all(from(r in QuestionLog, where: r.id == ^after_row.id),
      set: [question: "Can a player trade after rolling?"]
    )

    for row <- [before_row, after_row] do
      Games.set_community_vote(row.id, confirmed_user("v1_#{row.id}").id, "up")
      Games.set_community_vote(row.id, confirmed_user("v2_#{row.id}").id, "up")
      assert Repo.get(QuestionLog, row.id).trust_score >= 3.0
    end

    assert :ok == DirectPromotionWorker.perform(%Oban.Job{args: %{}})

    # Both earned promotion on their own votes; neither is swallowed by the other.
    assert Repo.get(QuestionLog, before_row.id).promoted
    assert Repo.get(QuestionLog, after_row.id).promoted
  end
end
