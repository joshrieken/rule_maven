defmodule RuleMaven.Workers.PoolRebuildWorkerTest do
  @moduledoc """
  The pool is the only free answer path in the system, and `invalidate_pool/1`
  empties it on every rulebook edit. This worker is what refills it.

  Almost every test here is an EXCLUSION. Re-asking the wrong row is not a
  cosmetic bug: rebuilding a crew row publishes a private answer into the
  cross-user pool, rebuilding a community row overwrites a moderator's decision,
  and rebuilding pool-hit copies re-asks one question once per person who ever
  received it. The selection predicate is the whole worker.
  """
  use RuleMaven.DataCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  alias RuleMaven.Games.QuestionLog
  alias RuleMaven.{Games, Repo, Users}
  alias RuleMaven.Workers.{AskWorker, PoolRebuildWorker}

  # Oban isn't supervised in test, and both the invalidation hook and the worker
  # itself insert jobs. Same convention as the other enqueue-asserting tests.
  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp user_fixture do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Users.create_user(%{
        username: "pr_user_#{n}",
        email: "pr_user_#{n}@test.com",
        password: "testpass1234"
      })

    u
  end

  defp game_with_doc do
    {:ok, game} = Games.create_game(%{name: "Rebuild #{System.unique_integer([:positive])}"})

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        kind: "rulebook",
        full_text: "seed"
      })

    {:ok, _} = Games.update_document(doc, %{status: "published"})
    game
  end

  # Distinct unit vectors, so two rows are "the same question" to the embedding
  # matcher only when they are given the same seed.
  defp vec(seed) do
    Pgvector.new(List.duplicate(0.0, 768) |> List.replace_at(rem(seed, 768), 1.0))
  end

  # A row in the state `invalidate_pool/1` leaves behind: previously servable,
  # now staled and demoted.
  defp staled_row(game, attrs \\ %{}) do
    base = %{
      game_id: game.id,
      user_id: user_fixture().id,
      question: "How many cards do I draw?",
      cleaned_question: "how many cards do i draw",
      question_embedding: vec(1),
      answer: "You draw five cards.",
      citation_valid: true,
      browsable: true,
      pooled: false,
      stale: true,
      refused: false,
      blocked: false,
      promoted: false,
      expansion_ids: []
    }

    Repo.insert!(struct!(QuestionLog, Map.merge(base, attrs)))
  end

  defp run_worker(game) do
    perform_job(PoolRebuildWorker, %{"game_id" => game.id})
  end

  defp ask_jobs do
    all_enqueued(worker: AskWorker)
  end

  describe "refilling the pool" do
    test "re-asks a previously-servable staled question with no user attached" do
      game = game_with_doc()
      staled_row(game)

      assert :ok = run_worker(game)

      assert [job] = ask_jobs()
      assert job.args["game_id"] == game.id
      assert job.args["question"] == "how many cards do i draw"

      # user_id nil is load-bearing: a rebuild must not spend a user's quota, must
      # not accrue to their trust score, and must not be mistaken for the asker's
      # own row by the same-user cache tiers.
      assert job.args["user_id"] == nil
      assert job.args["group_id"] == nil

      # It re-asks through the ordinary path, so the provisional row exists and
      # AskWorker's own grounding/citation/pooling gates decide its fate.
      ql = Repo.get(QuestionLog, job.args["question_log_id"])
      assert ql.answer == "Thinking..."
      assert ql.user_id == nil
      assert ql.game_id == game.id
    end

    test "asks each distinct question once, however many rows carried it" do
      game = game_with_doc()
      staled_row(game)
      staled_row(game)
      staled_row(game, %{cleaned_question: "what happens on a seven"})

      assert :ok = run_worker(game)

      questions = ask_jobs() |> Enum.map(& &1.args["question"]) |> Enum.sort()
      assert questions == ["how many cards do i draw", "what happens on a seven"]
    end

    test "the same question under different expansions is a different question" do
      game = game_with_doc()
      staled_row(game, %{expansion_ids: []})
      staled_row(game, %{expansion_ids: [42]})

      assert :ok = run_worker(game)
      assert length(ask_jobs()) == 2
    end

    test "caps the spend a single rulebook edit can authorize" do
      game = game_with_doc()
      RuleMaven.Settings.put("pool_rebuild_max_questions", "2")
      on_exit(fn -> RuleMaven.Settings.put("pool_rebuild_max_questions", "") end)

      for i <- 1..5, do: staled_row(game, %{cleaned_question: "question number #{i}"})

      assert :ok = run_worker(game)
      assert length(ask_jobs()) == 2
    end
  end

  describe "rows it must NOT rebuild" do
    test "a crew row — rebuilding one would publish a private answer to the pool" do
      game = game_with_doc()
      group = RuleMaven.GroupsFixtures.group_fixture(user_fixture())
      staled_row(game, %{group_id: group.id})

      assert :ok = run_worker(game)
      assert ask_jobs() == []
    end

    test "a community row — a moderator re-approves those, not this worker" do
      game = game_with_doc()
      staled_row(game, %{promoted: true})

      assert :ok = run_worker(game)
      assert ask_jobs() == []
    end

    test "a pool-hit COPY — the original is what gets rebuilt" do
      game = game_with_doc()
      original = staled_row(game)
      staled_row(game, %{pool_source_id: original.id})

      assert :ok = run_worker(game)

      # One ask, not two: the copy rides on the original's rebuild. Otherwise a
      # popular question is re-asked once per person who ever received it.
      assert length(ask_jobs()) == 1
    end

    test "an answer that never cleared the citation gate" do
      game = game_with_doc()
      staled_row(game, %{citation_valid: false})

      assert :ok = run_worker(game)
      assert ask_jobs() == []
    end

    test "a refused, blocked, or errored answer" do
      game = game_with_doc()
      staled_row(game, %{refused: true, cleaned_question: "a"})
      staled_row(game, %{blocked: true, cleaned_question: "b"})
      staled_row(game, %{error_kind: "timeout", cleaned_question: "c"})

      assert :ok = run_worker(game)
      assert ask_jobs() == []
    end

    test "an 'ask exactly this' row, which has no cleaned_question and never pools" do
      game = game_with_doc()
      staled_row(game, %{cleaned_question: nil})
      staled_row(game, %{cleaned_question: ""})

      assert :ok = run_worker(game)
      assert ask_jobs() == []
    end

    test "a question somebody already re-asked and re-pooled since the invalidation" do
      game = game_with_doc()
      staled_row(game)

      # The live row that a user's own ask (or an earlier rebuild) already
      # produced. Its `cleaned_question` is DELIBERATELY different: a rebuilt row
      # is normalized afresh, so its canonical text routinely differs from the
      # stale row that seeded it ("What causes Terror Level increase?" vs "What
      # causes the Terror Level to increase?"). Matching on text equality made the
      # rebuild fail to recognise its own output and re-buy the whole question set
      # on every rulebook edit — so this must match on the EMBEDDING.
      staled_row(game, %{
        stale: false,
        pooled: true,
        cleaned_question: "how many cards must be drawn at setup",
        question_embedding: vec(1)
      })

      assert :ok = run_worker(game)

      # Paying for an answer we already hold is the exact waste this worker exists
      # to remove.
      assert ask_jobs() == []
    end

    # The other half of the test above. Matching on the embedding is right, but the
    # embedding cannot see the token that decides the answer: "can a player trade
    # AFTER rolling" sits 0.93 from "can a player trade BEFORE rolling", inside the
    # pool's own threshold. Skipping on distance alone would drop the stale
    # question from THIS rebuild and from every rebuild after it.
    test "a stale question whose pooled near-neighbour asks the OPPOSITE is still rebuilt" do
      game = game_with_doc()

      staled_row(game, %{
        cleaned_question: "can a player trade after rolling",
        question_embedding: vec(1)
      })

      # Same embedding seed: to the matcher these are the same question.
      staled_row(game, %{
        stale: false,
        pooled: true,
        cleaned_question: "can a player trade before rolling",
        question_embedding: vec(1)
      })

      assert :ok = run_worker(game)

      assert [job] = ask_jobs()
      assert job.args["question"] == "can a player trade after rolling"
    end

    test "a rebuild is idempotent — re-running it queues nothing" do
      game = game_with_doc()
      staled_row(game, %{cleaned_question: "q one", question_embedding: vec(1)})
      staled_row(game, %{cleaned_question: "q two", question_embedding: vec(2)})

      assert :ok = run_worker(game)
      assert length(ask_jobs()) == 2

      # Simulate what AskWorker does to the rows the first pass queued: they come
      # back answered, grounded and pooled, under freshly-normalized canonical text.
      for {j, i} <- Enum.with_index(ask_jobs(), 1) do
        Repo.get!(QuestionLog, j.args["question_log_id"])
        |> Ecto.Changeset.change(%{
          answer: "An answer.",
          citation_valid: true,
          browsable: true,
          pooled: true,
          stale: false,
          cleaned_question: "freshly normalized text #{i}",
          question_embedding: vec(i)
        })
        |> Repo.update!()
      end

      Repo.delete_all(Oban.Job)

      # The second rebuild must recognise its own output and queue NOTHING. Before
      # the embedding match this re-asked every question, on every rulebook edit.
      assert :ok = run_worker(game)
      assert ask_jobs() == []
    end

    test "an unstaled row — there is nothing wrong with it" do
      game = game_with_doc()
      staled_row(game, %{stale: false})

      assert :ok = run_worker(game)
      assert ask_jobs() == []
    end
  end

  describe "guards" do
    test "no-ops for a game with no published document" do
      {:ok, game} = Games.create_game(%{name: "Bare #{System.unique_integer([:positive])}"})
      staled_row(game)

      assert :ok = run_worker(game)

      # The common case during first ingest: cleanup invalidates on every page
      # while the game has nothing to ground an answer in yet.
      assert ask_jobs() == []
    end

    test "the kill switch stops it dead" do
      game = game_with_doc()
      staled_row(game)

      RuleMaven.Settings.put("pool_rebuild_enabled", "false")
      on_exit(fn -> RuleMaven.Settings.put("pool_rebuild_enabled", "") end)

      assert :ok = run_worker(game)
      assert ask_jobs() == []
    end
  end

  describe "the invalidation hook" do
    test "invalidate_pool enqueues a debounced rebuild" do
      game = game_with_doc()
      staled_row(game, %{stale: false, pooled: true})

      Games.invalidate_pool(game.id)

      assert [job] = all_enqueued(worker: PoolRebuildWorker)
      assert job.args == %{"game_id" => game.id}

      # Scheduled, not immediate: chunking and embedding may still be running
      # behind the invalidation, and rebuilding against a half-written corpus
      # would cache the result of a partial rulebook.
      assert job.scheduled_at
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
    end

    test "a page-by-page cleanup collapses into ONE rebuild, not one per page" do
      game = game_with_doc()
      staled_row(game, %{stale: false, pooled: true})

      for _ <- 1..5, do: Games.invalidate_pool(game.id)

      assert length(all_enqueued(worker: PoolRebuildWorker)) == 1
    end
  end
end
