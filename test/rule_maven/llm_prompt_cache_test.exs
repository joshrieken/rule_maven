defmodule RuleMaven.LLMPromptCacheTest do
  @moduledoc """
  The rulebook block is ~14k of a ~15k ask prompt and is byte-identical on every
  ask for a game, so it is marked as an explicit prompt-cache breakpoint. None of
  this is observable in an answer — a broken breakpoint just quietly bills full
  price — so the request body is the only place it can be pinned.
  """
  use RuleMaven.DataCase, async: false

  alias RuleMaven.{Games, LLM, Repo}
  alias RuleMaven.Games.Chunk

  defp published_doc(game) do
    {:ok, d} =
      Games.create_document(%{
        game_id: game.id,
        label: "Core Rulebook",
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

  setup do
    {:ok, game} = Games.create_game(%{name: "CacheGame #{System.unique_integer([:positive])}"})
    doc = published_doc(game)
    put_chunk(doc, 1, "[Page 1]\nEach player draws 5 cards at setup.")
    put_chunk(doc, 2, "[Page 2]\nOn a 7, discard half your hand, rounded down.")

    Application.put_env(:rule_maven, :embed_mock, fn _text ->
      {:ok, List.duplicate(0.0, 768) |> List.replace_at(1, 1.0)}
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :embed_mock) end)

    %{game: game}
  end

  defp capture_bodies(fun) do
    test_pid = self()

    Application.put_env(:rule_maven, :llm_mock, fn body ->
      send(test_pid, {:llm_body, body})
      fun.(body)
    end)

    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end

  defp bodies(acc \\ []) do
    receive do
      {:llm_body, body} -> bodies([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp system_of(body), do: Enum.find(body.messages, &(&1.role == "system"))

  defp ask_bodies do
    bodies()
    |> Enum.filter(fn b ->
      case system_of(b) do
        nil -> false
        m -> is_list(m.content)
      end
    end)
  end

  describe "the rulebook prefix" do
    test "is marked as a cache breakpoint, and the per-turn tail is not", %{game: game} do
      capture_bodies(fn _ ->
        {:ok, %{answer: "You draw 5.", cited_passage: "[Page 1]", followups: []}}
      end)

      {:ok, _} = LLM.ask(game, "How many cards at setup?", [], [])

      [%{content: [prefix | rest]} | _] = Enum.map(ask_bodies(), &system_of/1)

      # The rulebook is the last thing in the cached half — everything a turn can
      # change (voice, recent conversation, corrective warnings) must fall after it.
      assert prefix.cache_control == %{type: "ephemeral"}
      assert prefix.text =~ "discard half your hand"
      assert Enum.all?(rest, &(not Map.has_key?(&1, :cache_control)))
    end

    test "is identical across different questions about the same game", %{game: game} do
      capture_bodies(fn _ ->
        {:ok, %{answer: "Ok.", cited_passage: "[Page 1]", followups: []}}
      end)

      {:ok, _} = LLM.ask(game, "How many cards at setup?", [], [])
      {:ok, _} = LLM.ask(game, "What happens on a 7?", [], [])

      # This is the whole point: a prefix that differs per question is a prefix
      # that never hits. Chunks are ordered by relevance TO THE QUESTION unless
      # the whole corpus is being sent, which is why whole-corpus retrieval sorts
      # by document instead.
      prefixes =
        Enum.map(ask_bodies(), fn body ->
          [prefix | _] = system_of(body).content
          prefix.text
        end)

      # Both asks, plus any retry rung either of them spent, must all present the
      # SAME prefix — a rung that rebuilt the block differently would silently pay
      # full price.
      assert length(prefixes) >= 2
      assert prefixes |> Enum.uniq() |> length() == 1
    end
  end

  describe "cache TTL" do
    test "the cheap model takes the default TTL", %{game: game} do
      capture_bodies(fn _ ->
        {:ok, %{answer: "You draw 5.", cited_passage: "[Page 1]", followups: []}}
      end)

      {:ok, _} = LLM.ask(game, "How many cards at setup?", [], [])

      [%{content: [prefix | _]} | _] = Enum.map(ask_bodies(), &system_of/1)

      # Gemini's TTL is not configurable through OpenRouter, so asking for one
      # would be noise in the request.
      assert prefix.cache_control == %{type: "ephemeral"}
    end

    test "an Anthropic model asks for the 1-hour TTL" do
      # The escalate model gets ONE call per ask, so on the default 5-minute TTL
      # every escalate is a cache WRITE (1.25x) and almost never a read — which
      # costs MORE than not caching. The 1-hour TTL pays 2x once and then reads at
      # 0.1x for the rest of the session, the window in which a group's questions
      # about one game actually land.
      assert LLM.__cache_control__("anthropic/claude-haiku-4.5") ==
               %{type: "ephemeral", ttl: "1h"}

      assert LLM.__cache_control__("google/gemini-2.5-flash") == %{type: "ephemeral"}
    end
  end
end
