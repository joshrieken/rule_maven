defmodule RuleMaven.LLMUncitedAnswerTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, LLM, Repo}
  alias RuleMaven.Games.Chunk

  @question "What is the maximum Terror Level?"
  @refusal "The rulebook does not cover this question."

  # A non-refusal answer with an EMPTY citations array is, by the answer
  # prompt's own rules, malformed: "Every non-refusal answer MUST have at least
  # one citation with a page set." Nothing enforced it, and two real failures
  # walked straight out of the gap — one answer that happened to be true but
  # unverifiable, and one that asserted a page-2 diagram the rulebook does not
  # contain. Without a quote there is no way to tell those apart, and no way for
  # a player at the table to check. So an uncited answer gets one corrective
  # retry, then refuses.
  defp seed_game do
    {:ok, game} = Games.create_game(%{name: "Uncited #{System.unique_integer([:positive])}"})

    {:ok, d} =
      Games.create_document(%{
        game_id: game.id,
        label: "Rulebook",
        kind: "rulebook",
        full_text: "seed"
      })

    {:ok, d} = Games.update_document(d, %{status: "published"})

    Repo.insert!(%Chunk{
      document_id: d.id,
      chunk_index: 1,
      content: "[Page 9]\nIf the Terror Level reaches the maximum, you lose.",
      page_number: 9,
      embedding: Pgvector.new(List.duplicate(0.1, 768))
    })

    game
  end

  defp mock_embed do
    Application.put_env(:rule_maven, :embed_mock, fn _text ->
      {:ok, List.duplicate(0.1, 768)}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)
  end

  defp mock_llm(ask_fun) do
    Process.put(:ask_calls, 0)

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      if body[:response_format] do
        n = Process.get(:ask_calls) + 1
        Process.put(:ask_calls, n)
        ask_fun.(n)
      else
        # Any non-ask call (normalize, critic, classifier). "grounded" keeps the
        # grounding critic out of the way so these tests isolate the citation
        # invariant; "NO" keeps the refusal-escalation classifier quiet.
        {:ok, %{answer: "VERDICT: grounded"}}
      end
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp uncited(answer) do
    {:ok,
     %{
       answer: answer,
       verdict: "info",
       citations: [],
       followups: [],
       also_asked: [],
       cited_passage: nil,
       cited_page: nil,
       cited_source: nil
     }}
  end

  defp cited(answer) do
    {:ok,
     %{
       answer: answer,
       verdict: "info",
       citations: [
         %{
           "quote" => "If the Terror Level reaches the maximum, you lose.",
           "page" => 9,
           "source" => "Rulebook"
         }
       ],
       followups: [],
       also_asked: [],
       cited_passage: "If the Terror Level reaches the maximum, you lose.",
       cited_page: 9,
       cited_source: "Rulebook"
     }}
  end

  test "an uncited answer is retried, and a cited retry is served" do
    game = seed_game()
    mock_embed()

    mock_llm(fn
      1 -> uncited("The Terror Level Track on page 2 shows a maximum of 6.")
      2 -> cited("Reaching the maximum Terror Level loses the game.")
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == "Reaching the maximum Terror Level loses the game."
    assert result.cited_page == 9
    refute result.citations == []
  end

  test "an answer that stays uncited after the retry refuses rather than shipping" do
    # The H7 shape: the model wants to assert a specific number it cannot quote.
    # Unciteable means ungrounded — refuse, do not serve a fact no one can check.
    game = seed_game()
    mock_embed()

    mock_llm(fn _n -> uncited("The Terror Level Track on page 2 shows a maximum of 6.") end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @refusal
    assert result.verdict == "silent"
    assert result.citations == []
  end

  test "a refusal is allowed to have no citations" do
    game = seed_game()
    mock_embed()

    mock_llm(fn _n ->
      {:ok,
       %{
         answer: @refusal,
         verdict: "silent",
         citations: [],
         followups: [],
         also_asked: [],
         cited_passage: nil,
         cited_page: nil
       }}
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @refusal
    # One ask call. A refusal must never be dragged into the uncited retry.
    assert Process.get(:ask_calls) == 1
  end

  test "a properly cited first answer is never retried" do
    game = seed_game()
    mock_embed()

    mock_llm(fn _n -> cited("Reaching the maximum Terror Level loses the game.") end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == "Reaching the maximum Terror Level loses the game."
    assert Process.get(:ask_calls) == 1
  end
end
