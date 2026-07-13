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
    # Distinct embedding per chunk — identical vectors get collapsed by the
    # retrieval near-duplicate dedup, and the classifier's quote verification
    # needs BOTH premises present in the context.
    Repo.insert!(%Chunk{
      document_id: doc.id,
      chunk_index: index,
      content: content,
      page_number: index,
      embedding: Pgvector.new(List.duplicate(0.0, 768) |> List.replace_at(index - 1, 1.0))
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

  # The classifier must now QUOTE the rules it claims combine; each quote is
  # substring-verified against the retrieved context before the expensive
  # escalation call is allowed to fire.
  defp classifier_yes_real_quotes do
    Jason.encode!(%{
      combinable: true,
      rules: [
        "Perk cards may be played only during the Hero Phase",
        "POW symbols are resolved during the Monster Phase"
      ]
    })
  end

  test "a combinable multi-hop refusal escalates to the stronger model and answers" do
    game = seed_multihop_corpus()

    mock_asks(classifier_yes_real_quotes(), fn
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

    mock_asks(Jason.encode!(%{combinable: false, rules: []}), fn
      1 -> refusal_result()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @refusal
    assert result.verdict == "silent"
    # Classifier said no — no stronger-model call spent.
    assert Process.get(:ask_calls) == 1
  end

  test "a YES built on quotes the context does not contain spends nothing" do
    game = seed_multihop_corpus()

    # The flash-lite classifier said YES on bait ("what is the maximum Terror
    # Level?") and burned an escalation call per false positive. A hallucinated
    # combination can't produce two real quotes, so verification kills it.
    fabricated =
      Jason.encode!(%{
        combinable: true,
        rules: [
          "The maximum Terror Level is 6 and the game ends there",
          "Heroes lose when the Terror Marker reaches the final space"
        ]
      })

    mock_asks(fabricated, fn
      1 -> refusal_result()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @refusal
    assert Process.get(:ask_calls) == 1
  end

  test "a YES with only one verifiable quote spends nothing" do
    game = seed_multihop_corpus()

    # "Combining two or more rules" needs two real rules — one verified quote
    # means the classifier padded or paraphrased its chain.
    one_real =
      Jason.encode!(%{
        combinable: true,
        rules: [
          "Perk cards may be played only during the Hero Phase",
          "POW symbols always hit twice during any phase"
        ]
      })

    mock_asks(one_real, fn
      1 -> refusal_result()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @refusal
    assert Process.get(:ask_calls) == 1
  end

  test "one real rule duplicated or respelled cannot pass as two" do
    game = seed_multihop_corpus()

    # Both entries verify against the context, but they're the SAME rule —
    # without dedup this bought an escalation with a single premise.
    padded =
      Jason.encode!(%{
        combinable: true,
        rules: [
          "Perk cards may be played only during the Hero Phase",
          "perk cards MAY be played, only during the hero phase!"
        ]
      })

    mock_asks(padded, fn
      1 -> refusal_result()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @refusal
    assert Process.get(:ask_calls) == 1
  end

  test "a real prefix spliced to a fabricated tail cannot verify" do
    game = seed_multihop_corpus()

    spliced =
      Jason.encode!(%{
        combinable: true,
        rules: [
          "Perk cards may be played only during the Hero Phase and also block POW symbols",
          "POW symbols are resolved during the Monster Phase"
        ]
      })

    mock_asks(spliced, fn
      1 -> refusal_result()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @refusal
    assert Process.get(:ask_calls) == 1
  end

  test "malformed rules shapes fail closed" do
    game = seed_multihop_corpus()

    # rules as a string instead of a list — the is_list guard must catch it.
    mock_asks(Jason.encode!(%{combinable: true, rules: "Perk cards may be played"}), fn
      1 -> refusal_result()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @refusal
    assert Process.get(:ask_calls) == 1
  end

  test "combinable true with the rules key missing fails closed" do
    game = seed_multihop_corpus()

    mock_asks(Jason.encode!(%{combinable: true}), fn
      1 -> refusal_result()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @refusal
    assert Process.get(:ask_calls) == 1
  end

  test "legacy bare YES/NO classifier output no longer triggers escalation" do
    game = seed_multihop_corpus()

    # Not JSON → unparseable → fail closed (no spend), never fail open.
    mock_asks("YES", fn
      1 -> refusal_result()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @refusal
    assert Process.get(:ask_calls) == 1
  end
end
