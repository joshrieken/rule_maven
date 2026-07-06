defmodule RuleMaven.LLMGroundingSalvageTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, LLM, Repo}
  alias RuleMaven.Games.Chunk

  @refusal "The rulebook does not cover this question."
  @question "What are the ways to counter a monster attack?"

  @grounded_quote "You may discard one Item for each Hit symbol rolled to defend."

  @aside "Perk cards cannot be played during the Monster Phase, so they do not counter attacks."

  # "cannot" (a trigger word) appears in the answer but not in the quote, so
  # Citations.suspicious?/2 fires and the grounding critic runs.
  @answer_with_aside "You may discard one Item per Hit symbol rolled (Page 8).\n\n" <> @aside

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

  defp seed_chunk(game) do
    doc = published_doc(game)

    Repo.insert!(%Chunk{
      document_id: doc.id,
      chunk_index: 1,
      content: "[Page 8]\n" <> @grounded_quote,
      page_number: 8,
      embedding: Pgvector.new(List.duplicate(0.1, 768))
    })
  end

  defp mock_embed do
    Application.put_env(:rule_maven, :embed_mock, fn _text ->
      {:ok, List.duplicate(0.1, 768)}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)
  end

  # Answer-model calls carry response_format; critics and normalize go through
  # chat/3 without it. Distinguish critics by their system prompt.
  defp mock_llm(ask_fun, critic_fun) do
    Process.put(:ask_calls, 0)
    Process.put(:critic_calls, 0)

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      cond do
        body[:response_format] ->
          n = Process.get(:ask_calls) + 1
          Process.put(:ask_calls, n)
          ask_fun.(n)

        Enum.any?(body.messages, fn m ->
          m.role == "system" and m.content =~ "adversarial fact-checker"
        end) ->
          n = Process.get(:critic_calls) + 1
          Process.put(:critic_calls, n)
          critic_fun.(n)

        true ->
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
       citations: [%{"quote" => @grounded_quote, "page" => 8}],
       followups: [],
       also_asked: [],
       cited_passage: @grounded_quote,
       cited_page: 8
     }}
  end

  test "a twice-flagged auxiliary clause is stripped, not the whole answer" do
    {:ok, game} = Games.create_game(%{name: "Salv #{System.unique_integer([:positive])}"})
    seed_chunk(game)
    mock_embed()

    mock_llm(
      fn _n -> answer_result(@answer_with_aside) end,
      fn _n -> {:ok, %{answer: "VERDICT: hallucinated\nFLAGGED: #{@aside}"}} end
    )

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer =~ "discard one Item"
    refute result.answer =~ "Perk cards"
    refute result.answer == @refusal
    assert result.verdict == "info"
    assert result.citations != []
  end

  test "falls back to the refusal when the flagged clause cannot be located" do
    {:ok, game} = Games.create_game(%{name: "Salv #{System.unique_integer([:positive])}"})
    seed_chunk(game)
    mock_embed()

    mock_llm(
      fn _n -> answer_result(@answer_with_aside) end,
      fn _n ->
        {:ok, %{answer: "VERDICT: hallucinated\nFLAGGED: Defeating a Monster lowers Terror."}}
      end
    )

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @refusal
    assert result.verdict == "silent"
  end

  test "a clean retry is kept unchanged" do
    {:ok, game} = Games.create_game(%{name: "Salv #{System.unique_integer([:positive])}"})
    seed_chunk(game)
    mock_embed()

    mock_llm(
      fn
        1 -> answer_result(@answer_with_aside)
        2 -> answer_result("You may discard one Item per Hit symbol rolled (Page 8).")
      end,
      fn
        1 -> {:ok, %{answer: "VERDICT: hallucinated\nFLAGGED: #{@aside}"}}
        _n -> {:ok, %{answer: "VERDICT: grounded"}}
      end
    )

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == "You may discard one Item per Hit symbol rolled (Page 8)."
    assert Process.get(:ask_calls) == 2
  end
end
