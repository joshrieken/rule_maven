defmodule RuleMaven.Workers.AskWorkerPersonaDirectTest do
  use RuleMaven.DataCase
  use Oban.Testing, repo: RuleMaven.Repo

  alias RuleMaven.{Games, Repo, Voices}
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
      Games.create_game(%{name: "PersonaDirectGame #{System.unique_integer([:positive])}"})

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Core rules",
        kind: "rulebook",
        full_text: "seed"
      })

    {:ok, doc} = Games.update_document(doc, %{status: "published"})

    put_chunk(doc, "[Page 5]\nRoll the d20 to determine the first player.", List.duplicate(0.1, 768))

    {:ok, ql} =
      Games.log_question(%{
        game_id: game.id,
        question: "How is the first player picked?",
        answer: "Thinking...",
        user_id: nil
      })

    Application.put_env(:rule_maven, :embed_mock, fn _ -> {:ok, List.duplicate(0.1, 768)} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

    %{game: game, ql: ql}
  end

  test "a fresh ask with a persona active caches the styled answer directly, no VoiceWorker job",
       %{game: game, ql: ql} do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: "The d20 picks the first player.",
         cited_passage: nil,
         styled_answer: "Arr, the d20 be pickin' the first player.",
         citations: [
           %{"quote" => "Roll the d20 to determine the first player.", "page" => 5, "source" => "Core rules"}
         ],
         verdict: "info",
         followups: [],
         also_asked: []
       }}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => nil,
               "skip_pool" => true,
               "voice" => "pirate"
             })

    updated = Games.get_question_log(ql.id)
    assert updated.answer == "The d20 picks the first player."

    assert Voices.get(ql.id, "pirate") == "Arr, the d20 be pickin' the first player."

    refute_enqueued worker: RuleMaven.Workers.VoiceWorker, args: %{question_log_id: ql.id}

    # The real broadcast shape must match what Voices.get/2 just proved got
    # written — pins AskWorker's payload to the LiveView's expectations so the
    # two don't silently drift apart (each has its own test hand-crafting the
    # message shape otherwise).
    assert_receive {:ask_complete,
                    %{
                      styled_voice: "pirate",
                      styled_answer: "Arr, the d20 be pickin' the first player."
                    }}
  end

  test "a game-generated (g:) persona is restyled inline and broadcast with the answer, no VoiceWorker job",
       %{game: game, ql: ql} do
    # LLM.ask deliberately never emits styled_answer for generated voices (their
    # style string is LLM output and must not enter the rulebook-access prompt),
    # so AskWorker must run the rulebook-free restyle itself before broadcasting
    # — otherwise the client shows the plain answer with a second loader.
    :ok =
      Voices.replace_generated(game.id, [
        %{slug: "herald", label: "Woodland Herald", emoji: "🦉", style: "a courtly woodland herald"}
      ])

    canonical = "The d20 picks the first player."
    styled = "Hear ye! The d20 doth choose who plays first."

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      restyle? =
        Enum.any?(body.messages, fn m ->
          String.contains?(m.content, "courtly woodland herald")
        end)

      if restyle? do
        {:ok, %{answer: styled}}
      else
        {:ok,
         %{
           answer: canonical,
           cited_passage: nil,
           citations: [
             %{"quote" => "Roll the d20 to determine the first player.", "page" => 5, "source" => "Core rules"}
           ],
           verdict: "info",
           followups: [],
           also_asked: []
         }}
      end
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => nil,
               "skip_pool" => true,
               "voice" => "g:herald"
             })

    assert Voices.get(ql.id, "g:herald") == styled

    refute_enqueued worker: RuleMaven.Workers.VoiceWorker, args: %{question_log_id: ql.id}

    assert_receive {:ask_complete, %{styled_voice: "g:herald", styled_answer: ^styled}}
  end

  test "a refused question never broadcasts a styled answer, even if the LLM produced one", %{
    game: game,
    ql: ql
  } do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: "The rulebook does not cover this question.",
         cited_passage: nil,
         # Simulates a model that ignored the "don't style a refusal" framing —
         # defense-in-depth: AskWorker must not forward this regardless.
         styled_answer: "Arr, the scrolls be silent on this one, matey.",
         citations: [],
         verdict: "silent",
         followups: [],
         also_asked: []
       }}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")

    assert :ok =
             perform(%{
               "game_id" => game.id,
               "question_log_id" => ql.id,
               "question" => ql.question,
               "expansion_ids" => [],
               "user_id" => nil,
               "skip_pool" => true,
               "voice" => "pirate"
             })

    assert_receive {:ask_complete, data}
    assert data.refused == true
    assert data.styled_answer == nil
    assert data.styled_voice == nil

    # And the DB write must have been skipped too (same gate as the broadcast).
    assert Voices.get(ql.id, "pirate") == nil
  end

  test "a fresh ask with no persona (neutral) never writes to answer_voices", %{
    game: game,
    ql: ql
  } do
    Application.put_env(:rule_maven, :llm_mock, fn _body ->
      {:ok,
       %{
         answer: "The d20 picks the first player.",
         cited_passage: nil,
         citations: [
           %{"quote" => "Roll the d20 to determine the first player.", "page" => 5, "source" => "Core rules"}
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

    assert Voices.get(ql.id, "neutral") == nil
    assert Voices.get(ql.id, "pirate") == nil
  end
end
