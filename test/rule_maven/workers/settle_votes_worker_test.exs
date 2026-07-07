defmodule RuleMaven.Workers.SettleVotesWorkerTest do
  use RuleMaven.DataCase
  use Oban.Testing, repo: RuleMaven.Repo

  import RuleMaven.GamesFixtures

  alias RuleMaven.Games
  alias RuleMaven.Repo
  alias RuleMaven.Users
  alias RuleMaven.Workers.SettleVotesWorker

  # Oban isn't supervised in test (config :rule_maven, Oban, testing: :manual),
  # but the hooked event sites (do_verify, demote_user_answers, and
  # SettleVotesWorker.enqueue/2 itself) call Oban.insert/1, which needs a
  # named, configured instance to insert against. Start a queueless/pluginless
  # one under the default name so the plain (unnamed) insert call resolves for
  # real. (See test/rule_maven/house_rules_test.exs for the same pattern.)
  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp user_fixture(name) do
    {:ok, u} =
      Users.create_user(%{
        username: name,
        email: "#{name}@test.com",
        password: "testpass1234"
      })

    u
  end

  test "perform settles votes in the given direction" do
    game = game_fixture()
    author = user_fixture("author")
    voter = user_fixture("voter")

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        question: "Worker Q?",
        answer: "A.",
        user_id: author.id,
        pooled: true
      })

    Games.set_community_vote(q.id, voter.id, "up")

    assert :ok =
             perform_job(SettleVotesWorker, %{
               "question_log_id" => q.id,
               "outcome" => "confirmed",
               "event_at" => NaiveDateTime.to_iso8601(NaiveDateTime.utc_now())
             })

    assert Repo.reload!(voter).curator_points == 1
  end

  test "perform is a no-op for a missing row" do
    assert :ok =
             perform_job(SettleVotesWorker, %{
               "question_log_id" => -1,
               "outcome" => "confirmed",
               "event_at" => NaiveDateTime.to_iso8601(NaiveDateTime.utc_now())
             })
  end

  test "enqueue inserts a job with event_at" do
    game = game_fixture()

    {:ok, q} =
      Games.log_question(%{game_id: game.id, question: "E?", answer: "A.", pooled: true})

    SettleVotesWorker.enqueue(q.id, :confirmed)

    assert_enqueued(
      worker: SettleVotesWorker,
      args: %{"question_log_id" => q.id, "outcome" => "confirmed"}
    )
  end

  test "toggle_verified enqueues a confirmed settle" do
    game = game_fixture()
    author = user_fixture("vauthor")

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        question: "V?",
        answer: "A.",
        user_id: author.id,
        pooled: true
      })

    {:ok, _} = Games.toggle_verified(q)

    assert_enqueued(
      worker: SettleVotesWorker,
      args: %{"question_log_id" => q.id, "outcome" => "confirmed"}
    )
  end

  test "demote_user_answers enqueues rejected settles" do
    game = game_fixture()
    author = user_fixture("dauthor")

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        question: "D?",
        answer: "A.",
        user_id: author.id,
        pooled: true,
        visibility: "community"
      })

    assert Games.demote_user_answers(author.id) == 1

    assert_enqueued(
      worker: SettleVotesWorker,
      args: %{"question_log_id" => q.id, "outcome" => "rejected"}
    )
  end

  test "set_question_visibility promoting to community enqueues a confirmed settle" do
    game = game_fixture()
    author = user_fixture("mauthor")

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        question: "M?",
        answer: "A.",
        user_id: author.id,
        pooled: true,
        visibility: "private"
      })

    Games.set_question_visibility(q.id, "community")

    assert_enqueued(
      worker: SettleVotesWorker,
      args: %{"question_log_id" => q.id, "outcome" => "confirmed"}
    )
  end

  test "set_question_visibility demoting from community enqueues a rejected settle" do
    game = game_fixture()
    author = user_fixture("nauthor")

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        question: "N?",
        answer: "A.",
        user_id: author.id,
        pooled: true,
        visibility: "community"
      })

    Games.set_question_visibility(q.id, "private")

    assert_enqueued(
      worker: SettleVotesWorker,
      args: %{"question_log_id" => q.id, "outcome" => "rejected"}
    )
  end
end
