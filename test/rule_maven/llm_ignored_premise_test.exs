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

  defp refusal_result do
    {:ok,
     %{
       answer: "The rulebook does not cover this question.",
       verdict: "silent",
       citations: [],
       followups: [],
       also_asked: [],
       cited_passage: nil
     }}
  end

  # Pen round 3 (2026-07-13): "Do I discard 25% of my cards?" was refused
  # outright — normalize mangled the premise into nonsense and the gate's old
  # blanket refusal skip meant nothing rescued it. A stated fraction or percent
  # is un-refusable (the real rule exists to confirm or correct against), so a
  # refusal now spends the single retry — re-asked on the RAW question — when
  # the question asserts one. Plain-number refusals stay out (routine "what if
  # two players tie?" refusals must not buy retries).
  test "a refusal of a numeric-only-premise question stays out of the gate" do
    game = seed_corpus()

    mock_asks(fn
      1 -> refusal_result()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == "The rulebook does not cover this question."
    assert Process.get(:ask_calls) == 1
  end

  defp fraction_mock(question, answers_by_call) do
    Process.put(:ask_calls, 0)

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      if body[:response_format] do
        n = Process.get(:ask_calls) + 1
        Process.put(:ask_calls, n)
        answers_by_call.(n)
      else
        # Normalize echoes THIS question so the stated fraction survives.
        {:ok, %{answer: question}}
      end
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  test "a refusal of a fraction-premise question spends the retry" do
    game = seed_corpus()
    fraction_q = "Do I move the Terror Track down a third when a Monster is defeated?"

    correcting =
      answer_result(
        "No — defeating a Monster moves the Terror Track down one space, not a third."
      )

    fraction_mock(fraction_q, fn
      1 -> refusal_result()
      2 -> correcting
    end)

    {:ok, result} = LLM.ask(game, fraction_q)

    assert result.answer =~ "not a third"
    assert Process.get(:ask_calls) == 2
  end

  test "a refusal that survives the retry escalates" do
    game = seed_corpus()
    fraction_q = "Do I move the Terror Track down a third when a Monster is defeated?"

    fraction_mock(fraction_q, fn
      1 -> refusal_result()
      2 -> refusal_result()
      3 -> answer_result("No — the Terror Track moves down one space, not a third.")
    end)

    {:ok, result} = LLM.ask(game, fraction_q)

    # A stated proportion is un-refusable: the real rule always exists to confirm
    # or correct against. Refusing it twice is the double miss the escalate rung
    # exists for (pen round 6, 2026-07-14 — "a third or a quarter?" refused 3/3
    # because the rung skipped refusals outright).
    assert result.answer =~ "not a third"
    assert Process.get(:ask_calls) == 3
  end

  test "an escalate that also refuses leaves the refusal standing" do
    game = seed_corpus()
    fraction_q = "Do I move the Terror Track down a third when a Monster is defeated?"

    fraction_mock(fraction_q, fn
      1 -> refusal_result()
      2 -> refusal_result()
      3 -> refusal_result()
    end)

    {:ok, result} = LLM.ask(game, fraction_q)

    # The escalate costs one call and changes nothing — the truthful refusal is
    # still what the user sees, never a fabricated rescue.
    assert result.answer == "The rulebook does not cover this question."
    assert Process.get(:ask_calls) == 3
  end

  test "a refusal of a premise-free question never enters the gate" do
    game = seed_corpus()
    plain_q = "How does the Terror Track work?"

    Process.put(:ask_calls, 0)

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      if body[:response_format] do
        n = Process.get(:ask_calls) + 1
        Process.put(:ask_calls, n)
        refusal_result()
      else
        {:ok, %{answer: plain_q}}
      end
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    {:ok, result} = LLM.ask(game, plain_q)

    assert result.answer == "The rulebook does not cover this question."
    assert Process.get(:ask_calls) == 1
  end

  test "an asserted percentage refused first-pass is rescued by the raw re-ask" do
    game = seed_corpus()
    percent_q = "Do I move the Terror Track down 25% when a Monster is defeated?"

    correcting =
      answer_result(
        "No — defeating a Monster moves the Terror Track down one space, not 25% of it."
      )

    Process.put(:ask_calls, 0)

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      if body[:response_format] do
        n = Process.get(:ask_calls) + 1
        Process.put(:ask_calls, n)
        if n == 1, do: refusal_result(), else: correcting
      else
        {:ok, %{answer: percent_q}}
      end
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)

    {:ok, result} = LLM.ask(game, percent_q)

    assert result.answer =~ "not 25%"
    assert Process.get(:ask_calls) == 2
  end
end
