defmodule RuleMaven.LLMGroundingNarrowingTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, LLM, Repo}
  alias RuleMaven.Games.Chunk

  @question "What are the ways to counter a monster attack?"

  @grounded_quote "You may discard one Item for each Hit symbol rolled to defend."

  # "cannot" (a trigger word) is absent from the quote, so the suspicion
  # heuristic fires and the critic runs.
  @suspicious_answer "You may discard one Item per Hit symbol rolled. " <>
                       "Perk cards cannot be played during the Monster Phase."

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

  # Five chunks, the cited quote only in chunk 0, each tagged with a unique
  # FILLER-n marker so a critic call's excerpt block can be sized by counting
  # markers. Identical embeddings — retrieval order doesn't matter, narrowing
  # keeps the match plus its list neighbors wherever the match lands.
  defp seed_chunks(game) do
    doc = published_doc(game)

    for i <- 0..4 do
      content =
        if i == 0,
          do: "[Page 8]\n" <> @grounded_quote,
          else: "[Page #{10 + i}]\nFILLER-#{i} unrelated setup rules about tokens."

      # Mutually orthogonal one-hot embeddings: retrieval's near-duplicate
      # dedup (pairwise sim >= 0.97) collapses same-direction vectors to one
      # survivor, which would leave nothing to narrow.
      embedding =
        List.duplicate(0.0, 768) |> List.replace_at(i, 1.0)

      Repo.insert!(%Chunk{
        document_id: doc.id,
        chunk_index: i,
        content: content,
        page_number: if(i == 0, do: 8, else: 10 + i),
        embedding: Pgvector.new(embedding)
      })
    end
  end

  defp mock_embed do
    Application.put_env(:rule_maven, :embed_mock, fn _text ->
      {:ok, List.duplicate(0.1, 768)}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)
  end

  # The same five chunks, padded until the corpus busts the small-corpus char
  # budget. That is what puts a game on the top-k retrieval path, where the
  # prompt prefix varies per question and so cannot be cached — the only path
  # where narrowing still applies.
  defp seed_big_chunks(game) do
    doc = published_doc(game)
    padding = String.duplicate("Filler prose about tokens and tracks. ", 400)

    for i <- 0..4 do
      content =
        if i == 0,
          do: "[Page 8]\n" <> @grounded_quote <> "\n" <> padding,
          else: "[Page #{10 + i}]\nFILLER-#{i} unrelated setup rules about tokens.\n" <> padding

      Repo.insert!(%Chunk{
        document_id: doc.id,
        chunk_index: i,
        content: content,
        page_number: if(i == 0, do: 8, else: 10 + i),
        embedding: Pgvector.new(List.duplicate(0.0, 768) |> List.replace_at(i, 1.0))
      })
    end

    refute Games.small_corpus?([game.id])
  end

  # A message's content is a plain string, or — once a prompt-cache breakpoint
  # is marked on it — a list of `%{type: "text", text: ...}` parts. The critic's
  # rulebook rides the SYSTEM message when it is cacheable and the USER message
  # when it is not, so bodies are counted across every message.
  defp message_text(content) when is_binary(content), do: content
  defp message_text(parts) when is_list(parts), do: Enum.map_join(parts, "", & &1.text)

  defp body_text(body), do: Enum.map_join(body.messages, "\n", &message_text(&1.content))

  defp mock_llm(ask_fun, critic_fun) do
    Process.put(:ask_calls, 0)
    Process.put(:critic_calls, 0)
    Process.put(:critic_bodies, [])

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      cond do
        body[:response_format] ->
          n = Process.get(:ask_calls) + 1
          Process.put(:ask_calls, n)
          ask_fun.(n)

        body_text(body) =~ "adversarial fact-checker" ->
          n = Process.get(:critic_calls) + 1
          Process.put(:critic_calls, n)
          Process.put(:critic_bodies, Process.get(:critic_bodies) ++ [body_text(body)])
          critic_fun.(n)

        true ->
          {:ok, %{answer: @question}}
      end
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp answer_result do
    {:ok,
     %{
       answer: @suspicious_answer,
       verdict: "info",
       citations: [%{"quote" => @grounded_quote, "page" => 8}],
       followups: [],
       also_asked: [],
       cited_passage: @grounded_quote,
       cited_page: 8
     }}
  end

  defp filler_count(text) do
    Regex.scan(~r/FILLER-\d/, text) |> length()
  end

  # Narrowing bought one thing only: a critic call the size of the answer call
  # was too expensive to run on every suspicious answer. A cacheable corpus makes
  # the full-context call cheap, so it runs full-context on the FIRST pass — and
  # the full-context critic was always the sole authority for a destructive
  # verdict, so this is the accurate path, not merely the affordable one.
  test "a cacheable corpus judges the full context in one call — no narrowing, no confirm pass" do
    {:ok, game} = Games.create_game(%{name: "Narrow #{System.unique_integer([:positive])}"})
    seed_chunks(game)
    mock_embed()

    assert Games.small_corpus?([game.id])

    mock_llm(
      fn _n -> answer_result() end,
      fn _n -> {:ok, %{answer: "VERDICT: grounded"}} end
    )

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @suspicious_answer
    assert Process.get(:critic_calls) == 1

    [body] = Process.get(:critic_bodies)
    assert body =~ @grounded_quote
    assert filler_count(body) == 4
  end

  test "a cacheable corpus needs no confirm pass to act on a hallucinated verdict" do
    {:ok, game} = Games.create_game(%{name: "Narrow #{System.unique_integer([:positive])}"})
    seed_chunks(game)
    mock_embed()

    mock_llm(
      fn _n -> answer_result() end,
      # The single critic call already saw everything, so its verdict is final —
      # it goes straight to the corrective answer retry with no second opinion.
      fn _n -> {:ok, %{answer: "VERDICT: hallucinated\nFLAGGED: Perk cards cannot be played"}} end
    )

    {:ok, _result} = LLM.ask(game, @question)

    # The verdict goes straight to the corrective answer retry — and that retry's
    # answer is critiqued in its turn, which is the second call here. What must
    # never happen is a NARROWED call: every critic on a cacheable corpus sees
    # the whole corpus, so no verdict needs confirming against a fuller set.
    assert Process.get(:ask_calls) > 1
    assert Enum.all?(Process.get(:critic_bodies), &(filler_count(&1) == 4))
  end

  test "a corpus too large to cache still narrows, then confirms against the full set" do
    {:ok, game} = Games.create_game(%{name: "Narrow #{System.unique_integer([:positive])}"})
    seed_big_chunks(game)
    mock_embed()

    mock_llm(
      fn _n -> answer_result() end,
      fn
        1 -> {:ok, %{answer: "VERDICT: hallucinated\nFLAGGED: Perk cards cannot be played"}}
        2 -> {:ok, %{answer: "VERDICT: grounded"}}
      end
    )

    {:ok, result} = LLM.ask(game, @question)

    # Full-context critic exonerated the answer: kept verbatim, no answer retry.
    assert result.answer == @suspicious_answer
    assert Process.get(:ask_calls) == 1
    assert Process.get(:critic_calls) == 2

    [narrowed_body, full_body] = Process.get(:critic_bodies)
    assert filler_count(narrowed_body) < 4
    assert filler_count(full_body) == 4
  end
end
