defmodule RuleMaven.LLMSuspiciousAnswerRetryTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, LLM, Repo}
  alias RuleMaven.Games.Chunk

  @question "What are the ways to counter a monster attack?"

  # A real deepseek flake: correct rules, right citations, answer in Chinese.
  # suspicious_answer?/1's non-prose ratio flags it.
  @chinese_answer "英雄可以通过两种方式对抗怪物攻击：丢弃物品来防御，或使用战士和牧师的特殊行动效果。"

  @english_answer "Discard one Item per Hit symbol rolled, or use the Fighter's special action."

  defp seed_game do
    {:ok, game} = Games.create_game(%{name: "Susp #{System.unique_integer([:positive])}"})

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

  defp answer_result(answer) do
    {:ok,
     %{
       answer: answer,
       verdict: "info",
       citations: [%{"quote" => "discard one Item for each Hit symbol rolled", "page" => 8}],
       followups: [],
       also_asked: [],
       cited_passage: "discard one Item for each Hit symbol rolled",
       cited_page: 8
     }}
  end

  test "suspicious_answer? flags non-English prose but not normal answers" do
    assert LLM.suspicious_answer?(@chinese_answer)
    refute LLM.suspicious_answer?(@english_answer)
    refute LLM.suspicious_answer?("**Yes** — move into the location (Page 5).")
  end

  test "a wrong-language answer is retried once with a plain-English nudge" do
    game = seed_game()
    mock_embed()

    mock_llm(fn
      1 -> answer_result(@chinese_answer)
      2 -> answer_result(@english_answer)
    end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @english_answer
    assert Process.get(:ask_calls) == 2

    assert_receive {:ask_body, 2, body}
    nudge = List.last(body.messages)
    # user role, not system — deepseek ignored a trailing system message and
    # answered in Chinese again (2026-07-07); models reliably attend to the
    # last user message.
    assert nudge.role == "user"
    assert nudge.content =~ "English"
  end

  test "retries only once — a second suspicious reply is returned as-is" do
    game = seed_game()
    mock_embed()

    mock_llm(fn _n -> answer_result(@chinese_answer) end)

    {:ok, result} = LLM.ask(game, @question)

    assert result.answer == @chinese_answer
    assert Process.get(:ask_calls) == 2
  end
end
