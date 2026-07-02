defmodule RuleMaven.GamesPoolInvalidationTest do
  use RuleMaven.DataCase

  import Ecto.Query
  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.QuestionLog

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
    test "demotes auto-pooled rows and flags every row (community + private) for review" do
      game = game()
      auto = pooled_q(game, %{pooled: true})
      community = pooled_q(game, %{pooled: true, visibility: "community"})

      # 2 demoted (both pooled) + 2 flagged (auto/private + community).
      assert Games.invalidate_pool(game.id) == 4

      refute Repo.get!(QuestionLog, auto.id).pooled

      # Private rows are flagged too, so same-user lookups stop serving them
      # (find_user_duplicate/find_user_similar filter on needs_review == false).
      auto = Repo.get!(QuestionLog, auto.id)
      assert auto.visibility == "private"
      assert auto.needs_review

      # Community answer is preserved but flagged so it stops serving until a
      # moderator re-approves it.
      community = Repo.get!(QuestionLog, community.id)
      assert community.visibility == "community"
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

    test "user-tier lookups exclude a private answer flagged stale by a rulebook change" do
      game = game()

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

      # Eligible before the rulebook changes...
      assert {%{id: id}, _tier} =
               Games.find_user_duplicate(game.id, user.id, "how many cards do i draw", "x")

      assert id == q.id

      # A rulebook change invalidates the pool — the user's own cached answer,
      # computed against the old text, must stop being served too.
      Games.invalidate_pool(game.id)

      assert Games.find_user_duplicate(game.id, user.id, "how many cards do i draw", "x") == nil
    end

    test "the pool lookup skips a flagged community answer" do
      game = game()
      embedding = List.duplicate(0.1, 768)

      {:ok, q} =
        Games.log_question(%{game_id: game.id, question: "how to win", answer: "score points"})

      Repo.update_all(from(x in QuestionLog, where: x.id == ^q.id),
        set: [visibility: "community", question_embedding: Pgvector.new(embedding)]
      )

      # Eligible before flagging...
      assert {_q, _tier} = Games.find_similar_question_in_pool(game.id, embedding)

      # ...skipped once flagged for review.
      Games.invalidate_pool(game.id)
      assert Games.find_similar_question_in_pool(game.id, embedding) == nil
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
  end
end
