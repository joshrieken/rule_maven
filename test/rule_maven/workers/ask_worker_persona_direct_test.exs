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
