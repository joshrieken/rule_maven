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

        Enum.any?(body.messages, fn m ->
          m.role == "system" and m.content =~ "adversarial fact-checker"
        end) ->
          n = Process.get(:critic_calls) + 1
          Process.put(:critic_calls, n)
          user = Enum.find(body.messages, &(&1.role == "user"))
          Process.put(:critic_bodies, Process.get(:critic_bodies) ++ [user.content])
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

  test "grounded verdict on the narrowed context runs one critic call on a subset" do
    {:ok, game} = Games.create_game(%{name: "Narrow #{System.unique_integer([:positive])}"})
    seed_chunks(game)
    mock_embed()

    mock_llm(
      fn _n -> answer_result() end,
      fn _n -> {:ok, %{answer: "VERDICT: grounded"}} end
    )

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @suspicious_answer
    assert Process.get(:critic_calls) == 1

    [body] = Process.get(:critic_bodies)
    assert body =~ @grounded_quote
    # Narrowed to the matched chunk + neighbors — strictly fewer than the
    # 4 filler chunks retrieval returned.
    assert filler_count(body) < 4
  end

  test "a narrowed hallucinated verdict is confirmed against the full chunk set" do
    {:ok, game} = Games.create_game(%{name: "Narrow #{System.unique_integer([:positive])}"})
    seed_chunks(game)
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
