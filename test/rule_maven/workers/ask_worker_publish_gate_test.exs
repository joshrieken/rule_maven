defmodule RuleMaven.Workers.AskWorkerPublishGateTest do
  @moduledoc """
  Task 4: AskWorker writes a group ask unbrowsable and enqueues the publish
  check — except on the `skip_normalize` ("Ask exactly this") path, where the
  canonical question IS the raw user text and must never publish. Also
  verifies the per-group `contribute_to_community: false` switch folds into
  `never_pool` so a non-contributing group's asks are neither pooled nor
  browsable.
  """
  use RuleMaven.DataCase
  use Oban.Testing, repo: RuleMaven.Repo

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.GroupsFixtures
  alias RuleMaven.Games.Chunk
  alias RuleMaven.Workers.{AskWorker, PublishCheckWorker}

  # `PublishCheckWorker.enqueue/1` (and `TagQuestionWorker.enqueue/2`) no-op
  # under `Application.get_env(:rule_maven, Oban)[:testing] == :manual` — the
  # value `config/test.exs` sets, and the same value that keeps the Oban
  # supervisor itself out of the app's supervision tree in test
  # (`RuleMaven.Application.maybe_add_oban/1`). Without both a real named
  # `Oban` instance running AND that guard flipped off, `assert_enqueued`/
  # `refute_enqueued` on `PublishCheckWorker` can't distinguish "the call
  # happened" from "the call always no-ops in test" — see
  # `test/mix/tasks/backfill_weight_test.exs` for the same pattern used
  # against `BggEnrichWorker`.
  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    orig = Application.get_env(:rule_maven, Oban)
    Application.put_env(:rule_maven, Oban, Keyword.put(orig, :testing, :disabled))
    on_exit(fn -> Application.put_env(:rule_maven, Oban, orig) end)

    :ok
  end

  defp user(prefix) do
    n = System.unique_integer([:positive])

    {:ok, u} =
      RuleMaven.Users.create_user(%{
        username: "#{prefix}_#{n}",
        email: "#{prefix}_#{n}@test.com",
        password: "testpass1234"
      })

    u
  end

  defp perform(args),
    do: AskWorker.perform(%Oban.Job{id: System.unique_integer([:positive]), args: args})

  defp seeded_game(bgg_id) do
    {:ok, game} =
      Games.create_game(%{
        name: "PublishGateGame #{System.unique_integer([:positive])}",
        bgg_id: bgg_id
      })

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Core rules",
        kind: "rulebook",
        full_text: "seed"
      })

    {:ok, doc} = Games.update_document(doc, %{status: "published"})

    Repo.insert!(%Chunk{
      document_id: doc.id,
      chunk_index: 0,
      content: "[Page 1]\nRoll the die to start.",
      page_number: 1,
      embedding: Pgvector.new(List.duplicate(0.1, 768))
    })

    game
  end

  defp stub_ask(answer) do
    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)

    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: answer,
         citations: [
           %{"quote" => "Roll the die to start.", "page" => 1, "source" => "Core rules"}
         ],
         verdict: "info",
         followups: [],
         also_asked: []
       }}
    end)

    on_exit(fn ->
      Application.delete_env(:rule_maven, :embed_mock)
      Application.delete_env(:rule_maven, :llm_mock)
    end)
  end

  test "a group ask is written unbrowsable and enqueues the publish check" do
    game = seeded_game(9201)
    owner = user("pgw_group")
    grp = GroupsFixtures.group_fixture(owner)
    stub_ask("You roll the die to start.")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "How do I start?",
        answer: "Thinking...",
        visibility: "private",
        group_id: grp.id
      })

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => owner.id,
               "group_id" => grp.id,
               "skip_pool" => true
             })

    assert Repo.reload!(ql).browsable == false
    assert_enqueued(worker: PublishCheckWorker, args: %{"question_log_id" => ql.id})
  end

  test "a non-group ask stays browsable and enqueues no publish check" do
    game = seeded_game(9202)
    u = user("pgw_solo")
    stub_ask("You roll the die to start.")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: u.id,
        question: "How do I start?",
        answer: "Thinking...",
        visibility: "private"
      })

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => u.id,
               "skip_pool" => true
             })

    assert Repo.reload!(ql).browsable == true
    refute_enqueued(worker: PublishCheckWorker)
  end

  test "a skip_normalize group ask never enqueues the publish check" do
    game = seeded_game(9203)
    owner = user("pgw_verbatim")
    grp = GroupsFixtures.group_fixture(owner)
    stub_ask("You roll the die to start.")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "How do I start, Dave?",
        answer: "Thinking...",
        visibility: "private",
        group_id: grp.id
      })

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => owner.id,
               "group_id" => grp.id,
               "skip_pool" => true,
               "skip_normalize" => true
             })

    assert Repo.reload!(ql).browsable == false
    refute_enqueued(worker: PublishCheckWorker)
  end

  test "a re-queue with NO group_id arg still treats a group row as a group row" do
    # The admin unblock path (AdminLive.Security) re-enqueues AskWorker from the
    # row, and used to send no "group_id" / "never_pool" / "skip_normalize". Oban
    # args are untrusted: the ROW's group_id column decides. Otherwise the re-run
    # writes browsable: true (only PublishCheckWorker may do that) and skips the
    # publish check entirely.
    game = seeded_game(9205)
    owner = user("pgw_requeue")
    grp = GroupsFixtures.group_fixture(owner)
    stub_ask("You roll the die to start.")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "How do I start?",
        answer: "Thinking...",
        visibility: "private",
        group_id: grp.id
      })

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "recent_context" => [],
               "user_id" => owner.id,
               "skip_pool" => true
             })

    assert Repo.reload!(ql).browsable == false
    assert_enqueued(worker: PublishCheckWorker, args: %{"question_log_id" => ql.id})
  end

  test "a re-queue with no group_id arg honors the group's contribute_to_community: false" do
    game = seeded_game(9206)
    owner = user("pgw_requeue_noshare")
    grp = GroupsFixtures.group_fixture(owner, %{contribute_to_community: false})
    stub_ask("You roll the die to start.")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "How do I start?",
        answer: "Thinking...",
        visibility: "private",
        group_id: grp.id
      })

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => owner.id,
               "skip_pool" => true
             })

    updated = Repo.reload!(ql)
    assert updated.pooled == false
    assert updated.browsable == false
  end

  test "an ungrounded group ask is not pooled and runs no publish check" do
    # mark_pooled/1 no-ops when the citation isn't grounded in the source, so the
    # row never surfaces cross-user — screening it would burn an LLM call and
    # could flip browsable on a row that isn't even in the pool.
    game = seeded_game(9207)
    owner = user("pgw_ungrounded")
    grp = GroupsFixtures.group_fixture(owner)

    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)

    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: "You roll the die to start.",
         # A quote that appears nowhere in the chunk => citation_valid == false.
         citations: [
           %{"quote" => "Dragons always fly at dawn.", "page" => 1, "source" => "Core rules"}
         ],
         verdict: "info",
         followups: [],
         also_asked: []
       }}
    end)

    on_exit(fn ->
      Application.delete_env(:rule_maven, :embed_mock)
      Application.delete_env(:rule_maven, :llm_mock)
    end)

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "How do I start?",
        answer: "Thinking...",
        visibility: "private",
        group_id: grp.id
      })

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => owner.id,
               "group_id" => grp.id,
               "skip_pool" => true
             })

    updated = Repo.reload!(ql)
    assert updated.citation_valid == false
    assert updated.pooled == false
    assert updated.browsable == false
    refute_enqueued(worker: PublishCheckWorker)
  end

  test "a group with contribute_to_community: false does not pool its asks" do
    game = seeded_game(9204)
    owner = user("pgw_noshare")
    grp = GroupsFixtures.group_fixture(owner, %{contribute_to_community: false})
    stub_ask("You roll the die to start.")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "How do I start?",
        answer: "Thinking...",
        visibility: "private",
        group_id: grp.id
      })

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => owner.id,
               "group_id" => grp.id,
               "skip_pool" => true
             })

    updated = Repo.reload!(ql)
    assert updated.pooled == false
    assert updated.browsable == false
  end

  test "a re-queue does NOT re-pool a row the crew withdrew" do
    # Deleting the crew retracts its rows AND nilifies their group_id, so nothing
    # on the row says "crew" any more except its closed `browsable` flag. Without
    # reading that flag, contribute_to_community?(nil) answers "yes, contribute"
    # and the admin unblock re-queue puts an answer the crew explicitly withdrew
    # straight back into the shared cache.
    game = seeded_game(9207)
    owner = user("pgw_withdrawn")
    grp = GroupsFixtures.group_fixture(owner)
    stub_ask("You roll the die to start.")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "How do I start?",
        answer: "Thinking...",
        visibility: "private",
        group_id: grp.id
      })

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => owner.id,
               "group_id" => grp.id,
               "skip_pool" => true
             })

    # Precondition: a grounded crew answer really does pool (otherwise this test
    # would pass for the wrong reason).
    assert Repo.reload!(ql).pooled, "precondition: the grounded crew answer pooled"

    {:ok, :deleted} = RuleMaven.Groups.delete_group(owner, grp)

    withdrawn = Repo.reload!(ql)
    assert is_nil(withdrawn.group_id)
    refute withdrawn.pooled
    refute withdrawn.browsable

    # The admin unblock path proper: Security.unblock_question/1 resets the answer
    # to "Thinking...", which is what lets AskWorker past `answered_already?` and
    # re-run the ask for real. Without this the re-queue short-circuits and the
    # test would pass for the wrong reason.
    {:ok, _} = RuleMaven.Security.unblock_question(Repo.reload!(ql))

    # Re-queue with no group_id — the column is nil now.
    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => withdrawn.question,
               "expansion_ids" => [],
               "user_id" => owner.id,
               "skip_pool" => true
             })

    refute Repo.reload!(ql).pooled,
           "an answer the crew withdrew was put back into the commons"
  end

  # `never_pool` is read at the TOP of the job; `mark_pooled/1` runs after an ask
  # that can take 180 seconds. A retraction landing inside that window was simply
  # undone — the row was re-pooled off the stale consent value, and the publish
  # check (which only ever inspected `pooled`) then published the question text of
  # a crew that had explicitly withdrawn it.
  #
  # The retraction is driven from INSIDE the stubbed LLM call, which is exactly
  # where the real one lands.
  test "contribution turned off DURING the ask does not pool the answer" do
    game = seeded_game(9210)
    owner = user("pgw_race")
    grp = GroupsFixtures.group_fixture(owner)

    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)

    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      # The owner flips "contribute to the community" off while the ask is in
      # flight. retract_contributions/1 closes the row; the job must notice.
      {:ok, _} = RuleMaven.Groups.set_contribute(grp, owner, false)

      {:ok,
       %{
         answer: "You roll the die to start.",
         citations: [
           %{"quote" => "Roll the die to start.", "page" => 1, "source" => "Core rules"}
         ],
         verdict: "info",
         followups: [],
         also_asked: []
       }}
    end)

    on_exit(fn ->
      Application.delete_env(:rule_maven, :embed_mock)
      Application.delete_env(:rule_maven, :llm_mock)
    end)

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "How do I start?",
        answer: "Thinking...",
        visibility: "private",
        group_id: grp.id
      })

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => owner.id,
               "group_id" => grp.id,
               "skip_pool" => true
             })

    row = Repo.reload!(ql)

    refute row.pooled,
           "the ask re-pooled an answer the crew withdrew while it was still running"

    refute row.browsable
    assert row.retracted_at, "the retraction left no durable mark on the row"

    refute_enqueued(worker: PublishCheckWorker, args: %{"question_log_id" => ql.id})
  end

  # The crew's ANSWER feeding the commons is the one thing about a crew row that
  # publishes BY DESIGN — and it was the only artifact with no gate on it.
  #
  # The scrub that strips names is NORMALIZE, not the publish check. On the
  # skip_normalize ("Ask exactly this") path, LLM.ask sets match_text to the RAW
  # question, so the answer is generated from the asker's verbatim prose — and the
  # answer prompt's ARGUMENT-SETTLING rule explicitly tells the model to open with
  # the disputing players' names ("or the stated names"). That answer was then
  # pooled and served verbatim to the next stranger who asked something similar.
  # No scrub, no contribution.
  test "a skip_normalize crew ask never pools its answer (it was built from raw text)" do
    game = seeded_game(9212)
    owner = user("pgw_verbatim")
    grp = GroupsFixtures.group_fixture(owner)
    stub_ask("Dave is right — a prone figure can be snuck past.")

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        user_id: owner.id,
        question: "Dave says my rogue can sneak past because he is prone, Sam says no",
        answer: "Thinking...",
        visibility: "private",
        group_id: grp.id
      })

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => owner.id,
               "group_id" => grp.id,
               "skip_pool" => true,
               "skip_normalize" => true
             })

    row = Repo.reload!(ql)

    refute row.pooled,
           "a crew answer generated from unscrubbed text was served to the commons"

    refute row.browsable
    refute_enqueued(worker: PublishCheckWorker, args: %{"question_log_id" => ql.id})
  end
end
