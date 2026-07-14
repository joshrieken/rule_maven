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

  # The critic re-sends the rulebook on over half of all asks and, before this,
  # re-bought it every time (measured: 1% cached). Its excerpts block is the same
  # bytes on every question for a game, so it is a breakpoint of its own.
  describe "the grounding critic's excerpts prefix" do
    # A long answer over a short quote trips the length_ratio suspicion trigger,
    # which is what buys the critic call.
    @long_answer "You draw five cards at setup, and this applies to every player " <>
                   "regardless of seating order or the number of players in the game."

    defp critic_bodies do
      bodies()
      |> Enum.filter(fn b ->
        Enum.any?(b.messages, fn m ->
          m.role == "user" and
            (is_list(m.content) or is_binary(m.content)) and
            String.contains?(message_text(m.content), "RULEBOOK EXCERPTS:")
        end)
      end)
    end

    defp message_text(content) when is_binary(content), do: content
    defp message_text(parts) when is_list(parts), do: Enum.map_join(parts, "", & &1.text)

    defp answer_then_critic(body) do
      user = Enum.find(body.messages, &(&1.role == "user"))

      if user && String.contains?(message_text(user.content), "RULEBOOK EXCERPTS:") do
        # `raw: true` — the critic reads raw_response, not the ask-shaped answer.
        {:ok, %{answer: "", raw_response: "VERDICT: grounded", finish_reason: "stop"}}
      else
        {:ok,
         %{
           answer: @long_answer,
           cited_passage: "Each player draws 5 cards at setup.",
           citations: [
             %{"quote" => "Each player draws 5 cards at setup.", "page" => 1, "source" => "Core"}
           ],
           followups: []
         }}
      end
    end

    test "is marked, is document-ordered, and is identical across questions", %{game: game} do
      capture_bodies(&answer_then_critic/1)

      {:ok, _} = LLM.ask(game, "How many cards at setup?", [], [])
      {:ok, _} = LLM.ask(game, "What happens on a 7?", [], [])

      critics = critic_bodies()
      assert length(critics) >= 2

      prefixes =
        Enum.map(critics, fn body ->
          [prefix | rest] = Enum.find(body.messages, &(&1.role == "user")).content

          # The answer and its quotes change every call and must stay out of the
          # cached half, or the prefix never matches twice.
          assert prefix.cache_control == %{type: "ephemeral"}
          assert Enum.all?(rest, &(not Map.has_key?(&1, :cache_control)))
          refute prefix.text =~ "ANSWER:"

          prefix.text
        end)

      assert prefixes |> Enum.uniq() |> length() == 1

      # Document order, not retrieval order — page 1 before page 2 whatever the
      # question was about.
      [prefix | _] = prefixes
      assert prefix =~ "RULEBOOK EXCERPTS:"

      {p1, _} = :binary.match(prefix, "draws 5 cards")
      {p2, _} = :binary.match(prefix, "discard half your hand")
      assert p1 < p2
    end

    test "judges the FULL corpus on the first pass — no narrowing, no confirm pass", %{
      game: game
    } do
      capture_bodies(&answer_then_critic/1)

      {:ok, _} = LLM.ask(game, "How many cards at setup?", [], [])

      # Narrowing exists only to make an uncached critic affordable. With the
      # excerpts cached, the critic sees everything on the first pass — so ONE
      # critic call, carrying every chunk, and no second confirming call.
      assert [critic] = critic_bodies()

      text = message_text(Enum.find(critic.messages, &(&1.role == "user")).content)
      assert text =~ "draws 5 cards"
      assert text =~ "discard half your hand"
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
