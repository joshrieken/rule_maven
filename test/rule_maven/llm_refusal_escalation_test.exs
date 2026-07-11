defmodule RuleMaven.LLMRefusalEscalationTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, LLM, Repo}
  alias RuleMaven.Games.Chunk

  @refusal "The rulebook does not cover this question."
  @question "Can I move through a space containing a monster?"

  defp published_doc(game, label \\ "Rulebook", kind \\ "rulebook") do
    {:ok, d} =
      Games.create_document(%{game_id: game.id, label: label, kind: kind, full_text: "seed"})

    {:ok, d} = Games.update_document(d, %{status: "published"})
    d
  end

  defp put_chunk(doc, index, content, vec) do
    Repo.insert!(%Chunk{
      document_id: doc.id,
      chunk_index: index,
      content: content,
      page_number: 1,
      embedding: Pgvector.new(vec)
    })
  end

  defp sparse_vec(pairs) do
    Enum.reduce(pairs, List.duplicate(0.0, 768), fn {idx, val}, acc ->
      List.replace_at(acc, idx, val)
    end)
  end

  # Answer-model calls carry response_format (JSON); helper ops (normalize,
  # critics) go through chat/3 without it. Count only the former, echo the
  # question back for the latter so normalization is a no-op.
  defp mock_llm_asks(ask_fun) do
    Process.put(:ask_calls, 0)

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      if body[:response_format] do
        n = Process.get(:ask_calls) + 1
        Process.put(:ask_calls, n)
        ask_fun.(n, body)
      else
        {:ok, %{answer: @question}}
      end
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp mock_embed(vec) do
    Application.put_env(:rule_maven, :embed_mock, fn _text -> {:ok, vec} end)
    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)
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

  defp legal_result do
    {:ok,
     %{
       answer: "Yes — heroes may move into or out of a location with a monster.",
       verdict: "legal",
       citations: [],
       followups: [],
       also_asked: [],
       cited_passage: "You may move into or out of a location with a Monster"
     }}
  end

  test "a refusal on capped retrieval escalates once with wider retrieval and takes the substantive answer" do
    {:ok, game} = Games.create_game(%{name: "Esc #{System.unique_integer([:positive])}"})
    doc = published_doc(game)
    query_vec = sparse_vec([{0, 1.0}])

    # 12 fat noise chunks + 1 vector-distant answer chunk. Total chars blow the
    # small-corpus budget, so the boost stands down and the first retrieval is
    # capped at the default top-10 — the answer chunk (ranked 13th) is missed.
    # The escalated pass (limit 25) picks up all 13.
    filler = String.duplicate("wombat filler ", 450)

    for i <- 1..12 do
      put_chunk(doc, i, "[Page #{i}]\nnoise #{i} #{filler}", sparse_vec([{0, 0.9}, {i, 0.436}]))
    end

    put_chunk(
      doc,
      13,
      "[Page 13]\nHeroes may move into or out of a location with a monster.",
      sparse_vec([{50, 1.0}])
    )

    mock_embed(query_vec)

    mock_llm_asks(fn
      1, _body -> refusal_result()
      2, _body -> legal_result()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer =~ "move into or out of a location"
    assert result.verdict == "legal"
    # source_chunks must reflect what the model actually answered from.
    assert length(result.source_chunks) == 13
    assert Enum.any?(result.source_chunks, &(&1.content =~ "location with a monster"))
    assert Process.get(:ask_calls) == 2
  end

  test "no escalation when the first retrieval already covered the whole corpus" do
    {:ok, game} = Games.create_game(%{name: "NoEsc #{System.unique_integer([:positive])}"})
    doc = published_doc(game)

    for i <- 1..3 do
      put_chunk(doc, i, "[Page #{i}]\nsmall corpus chunk #{i}", sparse_vec([{i, 1.0}]))
    end

    mock_embed(sparse_vec([{1, 1.0}]))
    mock_llm_asks(fn _n, _body -> refusal_result() end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @refusal
    assert result.verdict == "silent"
    assert Process.get(:ask_calls) == 1
  end

  test "a second refusal after escalation keeps the refusal" do
    {:ok, game} = Games.create_game(%{name: "EscStill #{System.unique_integer([:positive])}"})
    doc = published_doc(game)
    filler = String.duplicate("wombat filler ", 450)

    for i <- 1..12 do
      put_chunk(doc, i, "[Page #{i}]\nnoise #{i} #{filler}", sparse_vec([{0, 0.9}, {i, 0.436}]))
    end

    put_chunk(doc, 13, "[Page 13]\nsomething unrelated entirely.", sparse_vec([{50, 1.0}]))

    mock_embed(sparse_vec([{0, 1.0}]))
    mock_llm_asks(fn _n, _body -> refusal_result() end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @refusal
    assert result.verdict == "silent"
    assert Process.get(:ask_calls) == 2
  end
end
