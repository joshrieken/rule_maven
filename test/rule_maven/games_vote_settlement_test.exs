defmodule RuleMaven.GamesVoteSettlementTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.{QuestionLog, QuestionVote}

  defp user(name) do
    Repo.insert!(%RuleMaven.Users.User{
      username: name,
      email: "#{name}@test.com",
      password_hash: "x"
    })
  end

  defp pooled_question(game, author) do
    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        user_id: author.id,
        question: "how many cards",
        answer: "Draw two.",
        visibility: "community"
      })

    Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id), set: [pooled: true])
    Repo.get!(QuestionLog, q.id)
  end

  test "a settled vote cannot be un-voted or flipped" do
    {:ok, game} = Games.create_game(%{name: "SettleGame"})
    author = user("settle_author")
    voter = user("settle_voter")
    q = pooled_question(game, author)

    assert {:ok, _} = Games.set_community_vote(q.id, voter.id, "up") |> ok()

    # Settlement awards the voter a curator point and freezes the vote.
    {:ok, _} = RuleMaven.Games.Curation.settle_votes(Repo.get!(QuestionLog, q.id), :confirmed)

    vote = Repo.get_by!(QuestionVote, question_log_id: q.id, user_id: voter.id)
    assert vote.settled_at
    assert vote.settled_outcome == "correct"

    # Un-voting would delete the row while the point stays banked, letting the
    # next terminal event settle a fresh vote and award the point again.
    assert {:error, :settled} = Games.set_community_vote(q.id, voter.id, "up")

    # Flipping keeps settled_outcome: "correct" while the vote now says "down".
    assert {:error, :settled} = Games.set_community_vote(q.id, voter.id, "down")

    still = Repo.get_by!(QuestionVote, question_log_id: q.id, user_id: voter.id)
    assert still.value == "up"
    assert still.settled_outcome == "correct"
  end

  test "an unsettled vote is still freely changed" do
    {:ok, game} = Games.create_game(%{name: "UnsettledGame"})
    author = user("unsettled_author")
    voter = user("unsettled_voter")
    q = pooled_question(game, author)

    Games.set_community_vote(q.id, voter.id, "up")
    Games.set_community_vote(q.id, voter.id, "down")

    vote = Repo.get_by!(QuestionVote, question_log_id: q.id, user_id: voter.id)
    assert vote.value == "down"
  end

  # set_community_vote returns the raw value or nil on toggle-off; normalize.
  defp ok(nil), do: {:ok, :deleted}
  defp ok({:error, _} = e), do: e
  defp ok(other), do: {:ok, other}
end
