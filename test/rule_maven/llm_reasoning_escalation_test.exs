defmodule RuleMaven.LLMReasoningEscalationTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, LLM, Repo}
  alias RuleMaven.Games.Chunk

  # A multi-hop question: no single sentence answers it, but two explicitly
  # stated rules (Perk timing + POW timing) combine to a "No". The default
  # model refused it in production; the reasoning escalation must recover it.
  @question "Can a Perk card block a POW symbol?"
  @refusal "The rulebook does not cover this question."

  defp published_doc(game) do
    {:ok, d} =
      Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        kind: "rulebook",
        full_text: "seed"
      })

    {:ok, d} = Games.update_document(d, %{status: "published"})
    d
  end

  defp put_chunk(doc, index, content) do
    Repo.insert!(%Chunk{
      document_id: doc.id,
      chunk_index: index,
      content: content,
      page_number: index,
      embedding: Pgvector.new(List.duplicate(0.0, 768) |> List.replace_at(0, 1.0))
    })
  end

  defp mock_embed do
    Application.put_env(:rule_maven, :embed_mock, fn _text ->
      {:ok, List.duplicate(0.0, 768) |> List.replace_at(0, 1.0)}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)
  end

  # Routes the three call shapes an ask makes in test mode: JSON answer calls
  # (response_format) count and run answer_fun; the combinability classifier
  # (its system prompt is unmistakable) returns the injected verdict; every
  # other helper call (normalize, critics, reground) echoes the question.
  defp mock_asks(classifier_verdict, answer_fun) do
    Process.put(:ask_calls, 0)

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      cond do
        body[:response_format] ->
          n = Process.get(:ask_calls) + 1
          Process.put(:ask_calls, n)
          answer_fun.(n)

        inspect(body) =~ "audit a REFUSED" ->
          {:ok, %{answer: classifier_verdict}}

        true ->
          {:ok, %{answer: @question}}
      end
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp refusal_result do
    {:ok,
     %{
       answer: @refusal,
       verdict: "silent",
       citations: [],
       followups: [],
       also_asked: [],
       cited_passage: nil
     }}
  end

  defp combined_result do
    {:ok,
     %{
       answer:
         "**No** — Perk cards may be played only during the Hero Phase, but POW symbols are resolved during the Monster Phase, so no Perk card can be played in time to block one.",
       verdict: "illegal",
       citations: [
         %{
           quote: "Perk cards may be played only during the Hero Phase",
           page: 1,
           source: "Rulebook"
         },
         %{
           quote: "POW symbols are resolved during the Monster Phase",
           page: 2,
           source: "Rulebook"
         }
       ],
       followups: [],
       also_asked: [],
       cited_passage: "Perk cards may be played only during the Hero Phase"
     }}
  end

  defp seed_multihop_corpus do
    {:ok, game} = Games.create_game(%{name: "Reason #{System.unique_integer([:positive])}"})
    doc = published_doc(game)
    # Small corpus: the first retrieval already holds both premises, so the
    # retrieval escalation bails (identical chunk set). Only the reasoning
    # escalation can rescue this.
    put_chunk(doc, 1, "[Page 1]\nPerk cards may be played only during the Hero Phase.")
    put_chunk(doc, 2, "[Page 2]\nPOW symbols are resolved during the Monster Phase.")
    mock_embed()
    game
  end

  test "a combinable multi-hop refusal escalates to the stronger model and answers" do
    game = seed_multihop_corpus()

    mock_asks("YES", fn
      1 -> refusal_result()
      2 -> combined_result()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer =~ "**No**"
    assert result.verdict == "illegal"
    # One refusal + one stronger-model recheck.
    assert Process.get(:ask_calls) == 2
  end

  test "a refusal the classifier rejects as non-combinable is left untouched" do
    game = seed_multihop_corpus()

    mock_asks("NO", fn
      1 -> refusal_result()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @refusal
    assert result.verdict == "silent"
    # Classifier said NO — no stronger-model call spent.
    assert Process.get(:ask_calls) == 1
  end
end
