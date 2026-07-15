defmodule RuleMaven.GamesPoolInvalidationTest do
  # Not async: clear_needs_review/1 enqueues a re-ask via Oban.insert/1, which
  # needs a named, configured instance the Oban.Testing facade provides.
  use RuleMaven.DataCase, async: false
  use Oban.Testing, repo: RuleMaven.Repo

  import Ecto.Query
  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.QuestionLog

  # Oban isn't supervised in test; the re-ask enqueue needs a named instance.
  setup do
    start_supervised!(
      {Oban, repo: RuleMaven.Repo, name: Oban, testing: :disabled, queues: false, plugins: false}
    )

    :ok
  end

  defp game, do: elem(Games.create_game(%{name: "Pool #{System.unique_integer([:positive])}"}), 1)

  defp pooled_q(game, attrs) do
    {:ok, q} =
      Games.log_question(Map.merge(%{game_id: game.id, question: "q", answer: "a"}, attrs))

    {1, _} =
      Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id), set: Map.to_list(attrs))

    Repo.get!(QuestionLog, q.id)
  end

  describe "chunk_document/1 transactional delete+insert" do
    test "a failed insert rolls back the delete (no orphaned zero-chunk document)" do
      game = game()

      {:ok, doc} =
        Games.create_document(%{game_id: game.id, label: "R", full_text: "alpha beta gamma text"})

      Games.chunk_document(doc)

      original =
        Repo.all(
          from c in RuleMaven.Games.Chunk, where: c.document_id == ^doc.id, select: c.content
        )
        |> Enum.sort()

      assert original != []

      # A NUL byte is invalid in Postgres text — inserting it reliably fails the
      # insert_all at the DB level. pages: [] forces chunk_document to fall back
      # to parsing full_text, which carries the poison byte straight into a
      # chunk's content.
      poisoned = %{doc | full_text: "bad " <> <<0>> <> " content", pages: []}

      assert_raise Postgrex.Error, fn -> Games.chunk_document(poisoned) end

      remaining =
        Repo.all(
          from c in RuleMaven.Games.Chunk, where: c.document_id == ^doc.id, select: c.content
        )
        |> Enum.sort()

      assert remaining == original
    end
  end

  describe "chunk_document uses effective (cleaned) text" do
    test "cleaned page text reaches the chunks, not the original" do
      game = game()

      {:ok, doc} =
        Games.create_document(%{
          game_id: game.id,
          label: "Rules",
          full_text: "original alpha text here"
        })

      Games.set_page_cleaned(doc.id, 0, "CLEANED alpha text here")
      Games.get_document!(doc.id) |> Games.chunk_document()

      contents =
        Repo.all(
          from c in RuleMaven.Games.Chunk, where: c.document_id == ^doc.id, select: c.content
        )
        |> Enum.join("\n")

      assert contents =~ "CLEANED"
      refute contents =~ "original alpha"
    end
  end

  describe "invalidate_pool/1" do
    test "demotes auto-pooled rows, stales every row, flags only community rows for review" do
      game = game()
      auto = pooled_q(game, %{pooled: true})
      community = pooled_q(game, %{pooled: true, visibility: "community"})

      # 2 demoted (both pooled) + 2 staled (private + community) + 1 flagged
      # (community only — needs_review is a moderation signal and must not
      # touch private rows).
      assert Games.invalidate_pool(game.id) == 5

      refute Repo.get!(QuestionLog, auto.id).pooled

      # Private rows get `stale` (so same-user lookups stop serving them) but
      # NOT `needs_review` — that would inflate the asker's moderation risk
      # score on every rulebook edit.
      auto = Repo.get!(QuestionLog, auto.id)
      assert auto.visibility == "private"
      assert auto.stale
      refute auto.needs_review

      # Community answer is preserved but staled AND flagged so it stops
      # serving until a moderator re-approves it.
      community = Repo.get!(QuestionLog, community.id)
      assert community.visibility == "community"
      assert community.stale
      assert community.needs_review

      # The review backlog count only reflects the flagged community row — the
      # moderator queue stays scoped to community content.
      assert Games.needs_review_count() == 1

      # clear_needs_review re-approves it.
      {:ok, _} = Games.clear_needs_review(community)
      refute Repo.get!(QuestionLog, community.id).needs_review

      # ...and drains once re-approved.
      assert Games.needs_review_count() == 0
    end

    test "clear_needs_review re-asks instead of trusting citations from the old rulebook" do
      game = game()

      # A community row whose citations were validated against the PREVIOUS
      # rulebook, then staled + flagged by the edit that changed it.
      community =
        pooled_q(game, %{
          visibility: "community",
          answer: "Old answer citing p.4.",
          citation_valid: true,
          pooled: false,
          stale: true,
          needs_review: true
        })

      {:ok, _} = Games.clear_needs_review(community)

      reloaded = Repo.get!(QuestionLog, community.id)

      # Flag cleared, but the answer is NOT re-served on the old citations:
      # it is reset and re-grounded against the current rulebook.
      refute reloaded.needs_review
      refute reloaded.citation_valid
      refute reloaded.pooled
      assert reloaded.answer == "Thinking..."

      # A re-ask for THIS row is enqueued (in place — reuses the row id).
      job =
        Repo.all(Oban.Job)
        |> Enum.find(&(&1.args["question_log_id"] == community.id))

      assert job, "expected an AskWorker re-ask enqueued for the re-approved row"
      assert job.worker == "RuleMaven.Workers.AskWorker"
    end

    test "user-tier lookups exclude a private answer marked stale by a rulebook change" do
      game = game()
      embedding = List.duplicate(0.1, 768)

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "stale_user_#{System.unique_integer([:positive])}",
          email: "stale_#{System.unique_integer([:positive])}@test.com",
          password_hash: "x"
        })

      {:ok, q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "How many cards do I draw?",
          answer: "Draw 2 cards.",
          cleaned_question: "how many cards do i draw",
          visibility: "private"
        })

      Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id),
        set: [question_embedding: Pgvector.new(embedding)]
      )

      # Eligible in both user tiers before the rulebook changes...
      assert {%{id: id}, _tier} =
               Games.find_user_duplicate(game.id, user.id, "how many cards do i draw", "x")

      assert id == q.id
      assert {%{id: ^id}, _tier} = Games.find_user_similar(game.id, user.id, embedding)

      # A rulebook change invalidates the pool — the user's own cached answer,
      # computed against the old text, must stop being served too.
      Games.invalidate_pool(game.id)

      assert Games.find_user_duplicate(game.id, user.id, "how many cards do i draw", "x") == nil
      assert Games.find_user_similar(game.id, user.id, embedding) == nil

      # The exclusion runs on `stale`, not `needs_review` — the moderation
      # signal stays untouched for a private row.
      q = Repo.get!(QuestionLog, q.id)
      assert q.stale
      refute q.needs_review
    end

    test "the pool lookup skips a flagged community answer" do
      game = game()
      embedding = List.duplicate(0.1, 768)

      {:ok, q} =
        Games.log_question(%{game_id: game.id, question: "how to win", answer: "score points"})

      # Promotion to community always sets `pooled` too — mirror that here,
      # since the visibility-only pool branch now carries the citation gate.
      Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id),
        set: [
          visibility: "community",
          pooled: true,
          question_embedding: Pgvector.new(embedding)
        ]
      )

      # Eligible before flagging...
      assert {_q, _tier} = Games.find_similar_question_in_pool(game.id, embedding)

      # ...skipped once flagged for review.
      Games.invalidate_pool(game.id)
      assert Games.find_similar_question_in_pool(game.id, embedding) == nil
    end

    test "the pool lookup skips a blocked answer" do
      game = game()
      embedding = List.duplicate(0.1, 768)

      {:ok, q} =
        Games.log_question(%{game_id: game.id, question: "how to win", answer: "score points"})

      Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id),
        set: [
          visibility: "community",
          pooled: true,
          blocked: true,
          question_embedding: Pgvector.new(embedding)
        ]
      )

      # A blocked answer must never serve cross-user, the same as the same-user
      # tiers already enforce.
      assert Games.find_similar_question_in_pool(game.id, embedding) == nil
    end

    test "the pool lookup skips a still-Thinking sentinel row" do
      game = game()
      embedding = List.duplicate(0.1, 768)

      {:ok, q} =
        Games.log_question(%{game_id: game.id, question: "how to win", answer: "Thinking..."})

      Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id),
        set: [
          visibility: "community",
          pooled: true,
          question_embedding: Pgvector.new(embedding)
        ]
      )

      # An in-flight "Thinking..." answer must never be served.
      assert Games.find_similar_question_in_pool(game.id, embedding) == nil
    end

    test "a failed (error_kind) answer is never served from any cache tier" do
      game = game()
      embedding = List.duplicate(0.1, 768)

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "err_cache_user",
          email: "err_cache@test.com",
          password_hash: "x"
        })

      {:ok, q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "how many cards",
          cleaned_question: "how many cards",
          answer: "⚠️ The AI returned an empty response. Please retry.",
          visibility: "private"
        })

      Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id),
        set: [
          error_kind: "empty",
          pooled: true,
          question_embedding: Pgvector.new(embedding)
        ]
      )

      # A repeat ask must NOT collapse onto the error row — the old code
      # served the ⚠️ text as a cache hit and deleted the fresh row, leaving
      # no way to re-ask out of it.
      assert Games.find_user_duplicate(game.id, user.id, "how many cards", "x") == nil
      assert Games.find_user_similar(game.id, user.id, embedding) == nil
      assert Games.find_similar_question_in_pool(game.id, embedding) == nil
    end

    test "a legacy ⚠️ answer (pre-error_kind) is excluded too" do
      game = game()
      embedding = List.duplicate(0.1, 768)

      user =
        Repo.insert!(%RuleMaven.Users.User{
          username: "legacy_err_user",
          email: "legacy_err@test.com",
          password_hash: "x"
        })

      {:ok, q} =
        Games.log_question(%{
          game_id: game.id,
          user_id: user.id,
          question: "how many dice",
          cleaned_question: "how many dice",
          answer: "⚠️ Something went wrong. Please retry.",
          visibility: "private"
        })

      Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id),
        set: [question_embedding: Pgvector.new(embedding)]
      )

      assert Games.find_user_duplicate(game.id, user.id, "how many dice", "x") == nil
      assert Games.find_user_similar(game.id, user.id, embedding) == nil
    end

    test "rechunk_all_documents invalidates the pool for every affected game" do
      game = game()
      q = pooled_q(game, %{pooled: true})

      {:ok, _doc} =
        Games.create_document(%{
          game_id: game.id,
          label: "Rules",
          full_text: String.duplicate("alpha beta gamma delta epsilon zeta. ", 40)
        })

      # create_document already invalidates the pool once; re-pool the row so we
      # can prove rechunk_all_documents invalidates it again on its own.
      Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id), set: [pooled: true])

      Games.rechunk_all_documents()

      refute Repo.get!(QuestionLog, q.id).pooled
    end

    test "create/update/delete document invalidate the pool" do
      game = game()
      q = pooled_q(game, %{pooled: true})

      # create a second document → invalidates
      {:ok, doc} =
        Games.create_document(%{game_id: game.id, label: "R", full_text: "alpha beta gamma"})

      refute Repo.get!(QuestionLog, q.id).pooled

      # re-pool, then a content edit invalidates again
      Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id), set: [pooled: true])
      {:ok, _} = Games.update_document(doc, %{full_text: "totally different text now"})
      refute Repo.get!(QuestionLog, q.id).pooled
    end

    test "rejecting a published document invalidates the pool" do
      game = game()

      {:ok, doc} =
        Games.create_document(%{game_id: game.id, label: "R", full_text: "alpha beta gamma"})

      q = pooled_q(game, %{pooled: true})

      # A status-only change never touches full_text, so update_document/2's
      # own invalidation guard does not fire — un-publishing a live source has
      # to invalidate explicitly, exactly as approving one does.
      {:ok, _} = Games.reject_document(doc)

      refute Repo.get!(QuestionLog, q.id).pooled
    end

    test "approving a document invalidates the pool" do
      game = game()

      {:ok, doc} =
        Games.create_document(%{
          game_id: game.id,
          label: "R",
          full_text: "alpha beta gamma",
          status: "pending_review"
        })

      q = pooled_q(game, %{pooled: true})

      {:ok, _} = Games.approve_document(doc)

      refute Repo.get!(QuestionLog, q.id).pooled
    end
  end
end
