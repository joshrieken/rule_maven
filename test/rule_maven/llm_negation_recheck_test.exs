defmodule RuleMaven.LLMNegationRecheckTest do
  @moduledoc """
  An answer that asserts a prohibition/replacement none of its quotes states
  gets one stronger-model recheck. Fixture is the real Nidavellir failure:
  "you do not take a card. Instead, you perform a coin trade" citing only the
  trade step of a choose-card → recruit → trade turn list.
  """
  use RuleMaven.DataCase

  alias RuleMaven.{Games, LLM, Repo}
  alias RuleMaven.Games.Chunk

  @question "Do you take a card when bidding 0?"
  @turn "Choose a card in the tavern being resolved. Recruit a Hero card if the conditions are right. Perform a coin trade if you played your coin of value 0."

  defp seed do
    {:ok, game} = Games.create_game(%{name: "Neg #{System.unique_integer([:positive])}"})

    {:ok, doc} =
      Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        kind: "rulebook",
        full_text: "seed"
      })

    {:ok, doc} = Games.update_document(doc, %{status: "published"})

    Repo.insert!(%Chunk{
      document_id: doc.id,
      chunk_index: 1,
      content: "[Page 9]\n" <> @turn,
      page_number: 9,
      embedding: Pgvector.new(List.duplicate(0.0, 768) |> List.replace_at(0, 1.0))
    })

    Application.put_env(:rule_maven, :embed_mock, fn _ ->
      {:ok, List.duplicate(0.0, 768) |> List.replace_at(0, 1.0)}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)
    game
  end

  defp mock_answers(answer_fun) do
    Process.put(:ask_calls, 0)

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      if body[:response_format] do
        n = Process.get(:ask_calls) + 1
        Process.put(:ask_calls, n)
        answer_fun.(n)
      else
        {:ok, %{answer: @question}}
      end
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp result(answer, verdict, quote) do
    {:ok,
     %{
       answer: answer,
       verdict: verdict,
       citations: [%{quote: quote, page: 9, source: "Rulebook"}],
       followups: [],
       also_asked: [],
       cited_passage: quote
     }}
  end

  @wrong "When bidding 0 you do not take a card. Instead, you perform a coin trade."
  @right "Yes, you still choose a card, recruit a Hero if eligible, then perform a coin trade."

  test "an unsupported 'do not … instead' answer is rechecked on the stronger model" do
    game = seed()

    mock_answers(fn
      1 -> result(@wrong, "info", "Perform a coin trade if you played your coin of value 0")
      2 -> result(@right, "legal", "Choose a card in the tavern being resolved")
    end)

    {:ok, res} = LLM.ask(game, @question)

    assert res.answer =~ "still choose a card"
    assert Process.get(:ask_calls) == 2
  end

  test "a recheck that refuses keeps the first answer" do
    game = seed()

    mock_answers(fn
      1 ->
        result(@wrong, "info", "Perform a coin trade if you played your coin of value 0")

      2 ->
        {:ok,
         %{
           answer: "The rulebook does not cover this question.",
           verdict: "silent",
           citations: [],
           followups: [],
           also_asked: [],
           cited_passage: nil
         }}
    end)

    {:ok, res} = LLM.ask(game, @question)
    assert res.answer == @wrong
    assert Process.get(:ask_calls) == 2
  end

  describe "unsupported_negation?/1" do
    test "flags a negative claim whose quotes are all affirmative" do
      assert LLM.unsupported_negation?(%{
               answer: @wrong,
               verdict: "info",
               citations: [%{quote: "Perform a coin trade if you played your coin of value 0"}]
             })
    end

    test "passes a negative claim a quote supports" do
      refute LLM.unsupported_negation?(%{
               answer: "No, you cannot trade the special gem.",
               verdict: "illegal",
               citations: [%{"quote" => "This gem cannot be traded."}]
             })

      refute LLM.unsupported_negation?(%{
               answer: "No, only the lowest and highest gems are traded.",
               verdict: "illegal",
               citations: [
                 %{quote: "Only the lowest value gem and the highest value gem are traded"}
               ]
             })
    end

    test "ignores affirmative answers, refusals and uncited answers" do
      refute LLM.unsupported_negation?(%{
               answer: @right,
               verdict: "legal",
               citations: [%{quote: @turn}]
             })

      refute LLM.unsupported_negation?(%{
               answer: "The rulebook does not cover this question.",
               verdict: "silent",
               citations: []
             })

      refute LLM.unsupported_negation?(%{answer: @wrong, verdict: "info", citations: []})
    end
  end
end
