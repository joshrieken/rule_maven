defmodule RuleMaven.Workers.AskWorkerCitationsTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo}
  alias RuleMaven.Games.Chunk
  alias RuleMaven.Workers.AskWorker

  defp perform(args),
    do: AskWorker.perform(%Oban.Job{id: System.unique_integer([:positive]), args: args})

  defp put_chunk(doc, content, vec) do
    Repo.insert!(%Chunk{
      document_id: doc.id,
      chunk_index: 0,
      content: content,
      page_number: 1,
      embedding: Pgvector.new(vec)
    })
  end

  setup do
    {:ok, game} =
      Games.create_game(%{name: "CitationTestGame #{System.unique_integer([:positive])}"})

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Core rules",
        kind: "rulebook",
        full_text: "seed"
      })

    {:ok, doc} = Games.update_document(doc, %{status: "published"})

    # Distinct (non-parallel) vectors so retrieval's near-duplicate dedup
    # (cosine similarity >= 0.97 collapses to one chunk) doesn't collapse
    # these two down to a single chunk — identical vectors would.
    vec_a = List.duplicate(0.1, 384) ++ List.duplicate(0.05, 384)
    vec_b = List.duplicate(0.05, 384) ++ List.duplicate(0.1, 384)

    put_chunk(doc, "[Page 5]\nRoll the d20 to determine the first player.", vec_a)
    put_chunk(doc, "[Page 11]\nDamage the Beholder's eyestalks by rolling the d20.", vec_b)

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        question: "How is the d20 used?",
        answer: "Thinking...",
        user_id: nil
      })

    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

    %{game: game, ql: ql}
  end

  test "persists multiple grounded citations and mirrors the first into scalar fields", %{
    game: game,
    ql: ql
  } do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: "The d20 picks the first player and damages the Beholder's eyestalks.",
         cited_passage: nil,
         citations: [
           %{
             "quote" => "Roll the d20 to determine the first player.",
             "page" => 5,
             "source" => "Core rules"
           },
           %{
             "quote" => "Damage the Beholder's eyestalks by rolling the d20.",
             "page" => 11,
             "source" => "Core rules"
           }
         ],
         verdict: "info",
         followups: [],
         also_asked: []
       }}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => nil,
               "skip_pool" => true
             })

    updated = Games.get_question_log(ql.id)

    assert length(updated.citations) == 2
    assert Enum.at(updated.citations, 0)["page"] == 5
    assert Enum.at(updated.citations, 1)["page"] == 11
    assert updated.cited_page == 5
    assert updated.cited_passage =~ "first player"
    assert updated.citation_valid == true
  end

  test "drops an ungrounded citation but keeps the grounded ones", %{game: game, ql: ql} do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: "The d20 picks the first player.",
         cited_passage: nil,
         citations: [
           %{
             "quote" => "Roll the d20 to determine the first player.",
             "page" => 5,
             "source" => "Core rules"
           },
           %{
             "quote" => "the dragon devours two villages each dawn",
             "page" => 999,
             "source" => "Core rules"
           }
         ],
         verdict: "info",
         followups: [],
         also_asked: []
       }}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => nil,
               "skip_pool" => true
             })

    updated = Games.get_question_log(ql.id)

    assert length(updated.citations) == 1
    assert Enum.at(updated.citations, 0)["page"] == 5
    assert updated.citation_valid == true
  end

  test "all-ungrounded citations yield an empty list and citation_valid false", %{
    game: game,
    ql: ql
  } do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: "Something.",
         cited_passage: nil,
         citations: [%{"quote" => "invented nonsense", "page" => 999, "source" => nil}],
         verdict: "info",
         followups: [],
         also_asked: []
       }}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => nil,
               "skip_pool" => true
             })

    updated = Games.get_question_log(ql.id)

    assert updated.citations == []
    assert updated.cited_page == nil
    assert updated.citation_valid == false
  end

  test "a cross-user pool hit preserves the pooled citations instead of re-validating against nothing",
       %{game: game} do
    author =
      Repo.insert!(%RuleMaven.Users.User{
        username: "pool_author_#{System.unique_integer([:positive])}",
        email: "pool_author_#{System.unique_integer([:positive])}@test.com",
        password_hash: "x"
      })

    embedding = List.duplicate(0.42, 768)

    # The already-validated, pooled source row from a different user — its
    # citations were computed and persisted the first time it was answered,
    # against real retrieved chunks. There's no retrieval on a cache serve,
    # so this pool hit must copy these values through unchanged rather than
    # re-validating them against zero chunks.
    {:ok, pooled} =
      Games.log_question(%{
        game_id: game.id,
        user_id: author.id,
        question: "How is the d20 used to pick a player?",
        answer: "The d20 picks the first player.",
        cited_passage: "Roll the d20 to determine the first player.",
        cited_page: 5,
        cited_source: "Core rules",
        citations: [
          %{
            "quote" => "Roll the d20 to determine the first player.",
            "page" => 5,
            "source" => "Core rules"
          }
        ],
        citation_valid: true,
        pooled: true,
        visibility: "private"
      })

    Repo.update_all(
      from(ql in RuleMaven.Games.QuestionLog, where: ql.id == ^pooled.id),
      set: [question_embedding: Pgvector.new(embedding)]
    )

    # The fresh, differently-worded question from a different asker. Provisional
    # row pre-logged by the LiveView, same as production flow.
    {:ok, fresh} =
      Games.log_question(%{
        game_id: game.id,
        question: "Who goes first — how do we decide?",
        answer: "Thinking...",
        user_id: nil
      })

    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, embedding} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => fresh.id,
               "question" => fresh.question,
               "expansion_ids" => [],
               "user_id" => nil
             })

    updated = Games.get_question_log(fresh.id)

    assert updated.citations == [
             %{
               "quote" => "Roll the d20 to determine the first player.",
               "page" => 5,
               "source" => "Core rules"
             }
           ]

    assert updated.citation_valid == true
    assert updated.cited_passage == "Roll the d20 to determine the first player."
    assert updated.cited_page == 5
    assert updated.cited_source == "Core rules"
    assert updated.pool_source_id == pooled.id
  end

  # `valid_citations/2` drops every citation whose quote is not verbatim in the
  # retrieved chunks — correctly. But the ANSWER was still served afterwards,
  # so a fabricated quote was silently deleted and the fabrication it was
  # supporting shipped BARE: no citation, no warning, `citation_valid: false`,
  # rendered as an ordinary answer. Observed live — "The Rogue hero tile
  # indicates that they have 3 actions per turn", a number that appears nowhere
  # in the rulebook, with its invented quote stripped on the way out.
  #
  # Stripping the evidence is not a fix for an answer that had no evidence. If
  # nothing survives validation, the answer is ungrounded and must refuse.
  test "an answer whose every citation fails validation refuses instead of shipping bare", %{
    game: game,
    ql: ql
  } do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: "The Rogue hero tile indicates that they have 3 actions per turn.",
         cited_passage: nil,
         citations: [
           %{
             "quote" => "The Rogue has 3 actions per turn.",
             "page" => 5,
             "source" => "Core rules"
           }
         ],
         followups: [],
         also_asked: []
       }}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => nil
             })

    updated = Games.get_question_log(ql.id)

    assert updated.answer == "The rulebook does not cover this question."
    assert updated.refused == true
    assert updated.verdict == "silent"
    assert updated.citations == []
    assert updated.citation_valid == false
    assert updated.cited_passage == nil
  end

  test "a refusal is not disturbed by having no citations", %{game: game, ql: ql} do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: "The rulebook does not cover this question.",
         cited_passage: nil,
         citations: [],
         followups: [],
         also_asked: []
       }}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => nil
             })

    updated = Games.get_question_log(ql.id)

    assert updated.answer == "The rulebook does not cover this question."
    assert updated.refused == true
  end
end
