defmodule RuleMaven.LLMIgnoredPremiseTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, LLM, Repo}
  alias RuleMaven.Games.Chunk

  # A question that STATES a mid-game value which conflicts with a memorable
  # setup default. The failure this guards against: the model answers the
  # generic case from the setup rule (3 - 1 = 2), confidently, with valid
  # citations — invisible to the grounding critic.
  @question "Playing solo, the Terror Level is 0 and one Monster is defeated. What is the Terror Level now?"

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
      embedding: Pgvector.new(List.duplicate(0.0, 768) |> List.replace_at(index - 1, 1.0))
    })
  end

  defp seed_corpus do
    {:ok, game} = Games.create_game(%{name: "Premise #{System.unique_integer([:positive])}"})
    doc = published_doc(game)
    put_chunk(doc, 1, "[Page 1]\nIn a solo game the Terror Marker starts at Terror Level 3.")
    put_chunk(doc, 2, "[Page 2]\nWhen a Monster is defeated, move the Terror Track down one space.")

    Application.put_env(:rule_maven, :embed_mock, fn _text ->
      {:ok, List.duplicate(0.0, 768) |> List.replace_at(0, 1.0)}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)
    game
  end

  defp mock_asks(answer_fun) do
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

  defp answer_result(answer) do
    {:ok,
     %{
       answer: answer,
       verdict: "info",
       citations: [
         %{
           quote: "When a Monster is defeated, move the Terror Track down one space",
           page: 2,
           source: "Rulebook"
         }
       ],
       followups: [],
       also_asked: [],
       cited_passage: "When a Monster is defeated, move the Terror Track down one space"
     }}
  end

  # Never mentions the stated 0 — the setup-default answer.
  defp ignoring_answer,
    do:
      answer_result(
        "In a solo game the Terror Marker starts at Terror Level 3. Defeating a Monster moves the Terror Track down one space, so the Terror Level is 2."
      )

  # Engages the stated 0.
  defp engaged_answer,
    do:
      answer_result(
        "The rules do not specify what happens below 0. With the Terror Level at 0, defeating a Monster moves the track down one space, so it stays at 0."
      )

  test "an answer engaging every stated number passes with no retry" do
    game = seed_corpus()
    mock_asks(fn 1 -> engaged_answer() end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer =~ "stays at 0"
    assert Process.get(:ask_calls) == 1
  end

  test "an ignored stated value spends one retry, kept when it engages" do
    game = seed_corpus()

    mock_asks(fn
      1 -> ignoring_answer()
      2 -> engaged_answer()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer =~ "stays at 0"
    assert Process.get(:ask_calls) == 2
  end

  test "a double miss escalates once; the escalate answer wins when it engages" do
    game = seed_corpus()

    mock_asks(fn
      1 -> ignoring_answer()
      2 -> ignoring_answer()
      3 -> engaged_answer()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer =~ "stays at 0"
    assert Process.get(:ask_calls) == 3
  end

  test "an escalate answer that still ignores the value falls back to the retry" do
    game = seed_corpus()

    mock_asks(fn
      1 -> ignoring_answer()
      2 -> ignoring_answer()
      3 -> ignoring_answer()
    end)

    {:ok, result} = LLM.ask(game, @question)

    # No fourth call — the ladder ends at the escalate rung.
    assert Process.get(:ask_calls) == 3
    assert result.answer =~ "Terror Level is 2"
  end

  test "an asserted fraction the answer recites past spends one retry" do
    game = seed_corpus()

    fraction_q = "Playing solo, do I move the Terror Track down a third when a Monster is defeated?"

    reciting =
      answer_result("When a Monster is defeated, move the Terror Track down one space.")

    correcting =
      answer_result(
        "No — defeating a Monster moves the Terror Track down one space, not a third."
      )

    Process.put(:ask_calls, 0)

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      if body[:response_format] do
        n = Process.get(:ask_calls) + 1
        Process.put(:ask_calls, n)
        if n == 1, do: reciting, else: correcting
      else
        # Normalize echoes THIS question so the stated fraction survives.
        {:ok, %{answer: fraction_q}}
      end
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    {:ok, result} = LLM.ask(game, fraction_q)

    assert result.answer =~ "not a third"
    assert Process.get(:ask_calls) == 2
  end

  test "a refusal never enters the premise gate" do
    game = seed_corpus()

    mock_asks(fn
      1 ->
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

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == "The rulebook does not cover this question."
    # One first-pass call only — refusal paths own their own escalations
    # (classifier said nothing combinable here since the mock echoes the
    # question for non-answer calls).
    assert Process.get(:ask_calls) == 1
  end
end
