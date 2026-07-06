defmodule RuleMaven.LLMBlankAnswerRetryTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, LLM, Repo}
  alias RuleMaven.Games.Chunk

  @question "What are the ways to counter a monster attack?"

  # A model flake: syntactically valid JSON that is missing the "answer" key
  # decodes to a blank answer (decode_answer's schema branch).
  @junk_json ~s({"user_context": {"question": "counter?"}, "conversation_state": {}})

  defp seed_game do
    {:ok, game} = Games.create_game(%{name: "Blank #{System.unique_integer([:positive])}"})

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
      content: "[Page 8]\nYou may discard one Item for each Hit symbol rolled.",
      page_number: 8,
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
    parent = self()
    Process.put(:ask_calls, 0)

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      if body[:response_format] do
        n = Process.get(:ask_calls) + 1
        Process.put(:ask_calls, n)
        send(parent, {:ask_body, n, body})
        ask_fun.(n)
      else
        {:ok, %{answer: @question}}
      end
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp blank_result do
    {:ok,
     %{
       answer: "",
       citations: [],
       followups: [],
       also_asked: [],
       cited_passage: nil,
       verdict: nil,
       raw_response: @junk_json
     }}
  end

  defp good_result do
    {:ok,
     %{
       answer: "Discard one Item per Hit symbol rolled.",
       verdict: "info",
       citations: [%{"quote" => "discard one Item for each Hit symbol rolled", "page" => 8}],
       followups: [],
       also_asked: [],
       cited_passage: "discard one Item for each Hit symbol rolled",
       cited_page: 8
     }}
  end

  test "a blank answer is retried once with a cache-busting schema nudge" do
    game = seed_game()
    mock_embed()

    mock_llm(fn
      1 -> blank_result()
      2 -> good_result()
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == "Discard one Item per Hit symbol rolled."
    assert Process.get(:ask_calls) == 2

    # The retry must alter the messages array (the LLM proxy caches responses
    # keyed on messages) and re-state the schema requirement.
    assert_receive {:ask_body, 2, body}
    nudge = List.last(body.messages)
    assert nudge.role == "system"
    assert nudge.content =~ "answer"
  end

  test "retries only once — a second blank reply is returned as-is" do
    game = seed_game()
    mock_embed()

    mock_llm(fn _n -> blank_result() end)

    {:ok, result} = LLM.ask(game, @question)

    assert String.trim(result.answer || "") == ""
    assert Process.get(:ask_calls) == 2
  end

  test "a non-blank first answer is not retried" do
    game = seed_game()
    mock_embed()

    mock_llm(fn _n -> good_result() end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer =~ "Discard one Item"
    assert Process.get(:ask_calls) == 1
  end
end
