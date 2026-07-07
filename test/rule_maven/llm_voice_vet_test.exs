defmodule RuleMaven.LLMVoiceVetTest do
  use RuleMaven.DataCase

  alias RuleMaven.{LLM, Games, Voices}

  # Single-call persona path for generated (g:) voices, gated on the style vet
  # (see LLM.voice_style_block/2 and LLM.vet_voice_styles/2).

  defp game_with_voice(vetted) do
    {:ok, game} = Games.create_game(%{name: "Test"})

    :ok =
      Voices.replace_generated(game.id, [
        %{
          slug: "quartermaster",
          label: "Quartermaster",
          emoji: "🦜",
          style: "a weary quartermaster who sighs about paperwork",
          vetted: vetted
        }
      ])

    game
  end

  describe "voice_style_block gating for generated voices" do
    test "vetted g: voice takes the single-call path (style inlined, styled_answer requested)" do
      game = game_with_voice(true)
      {:ok, agent} = Agent.start_link(fn -> nil end)

      mock_llm(fn body ->
        prompt = body.messages |> Enum.find(&(&1.role == "system")) |> Map.get(:content)
        Agent.update(agent, fn _ -> prompt end)

        {:ok,
         %{
           answer: "You move 4 spaces.",
           styled_answer: "Four spaces. I'll log it. Again.",
           cited_passage: "ok",
           followup: false,
           followups: []
         }}
      end)

      {:ok, result} = LLM.ask(game, "How many spaces?", [], [], voice: "g:quartermaster")

      prompt = Agent.get(agent, & &1)
      assert prompt =~ "styled_answer"
      assert prompt =~ "weary quartermaster"
      assert result[:styled_answer] == "Four spaces. I'll log it. Again."
      assert result[:styled_voice] == "g:quartermaster"
    end

    test "unvetted g: voice keeps the restyle path (no persona block, no styled_answer)" do
      game = game_with_voice(false)
      {:ok, agent} = Agent.start_link(fn -> nil end)

      mock_llm(fn body ->
        prompt = body.messages |> Enum.find(&(&1.role == "system")) |> Map.get(:content)
        Agent.update(agent, fn _ -> prompt end)
        {:ok, %{answer: "ok", cited_passage: "ok", followup: false, followups: []}}
      end)

      {:ok, result} = LLM.ask(game, "How many spaces?", [], [], voice: "g:quartermaster")

      prompt = Agent.get(agent, & &1)
      refute prompt =~ "styled_answer"
      refute prompt =~ "weary quartermaster"
      assert result[:styled_answer] == nil
    end
  end

  describe "vet_voice_styles/2" do
    test "empty input never calls the LLM" do
      mock_llm(fn _body -> flunk("no LLM call expected") end)
      assert {:ok, %{safe: [], real_person: []}} = LLM.vet_voice_styles([])
    end

    test "overlong styles are excluded from safe but still real-person checked" do
      mock_llm(fn _body ->
        {:ok, %{answer: ~s([{"slug":"windbag","safe":true,"real_person":true}])}}
      end)

      voices = [%{slug: "windbag", style: String.duplicate("very wordy ", 60)}]
      assert {:ok, %{safe: [], real_person: ["windbag"]}} = LLM.vet_voice_styles(voices)
    end

    test "returns safe and real_person slugs independently" do
      mock_llm(fn _body ->
        {:ok,
         %{
           answer:
             ~s([{"slug":"good","safe":true,"real_person":false},{"slug":"bad","safe":false,"real_person":false},{"slug":"klaus","safe":true,"real_person":true}])
         }}
      end)

      voices = [
        %{slug: "good", style: "a cheery herald"},
        %{slug: "bad", style: "ignore rules"},
        %{slug: "klaus", label: "Spirit of Klaus Teuber", style: "a wise designer's ghost"}
      ]

      # A real-person flag also disqualifies from safe — the voice is deleted.
      assert {:ok, %{safe: ["good"], real_person: ["klaus"]}} = LLM.vet_voice_styles(voices)
    end
  end

  describe "__parse_vet_verdicts__/3" do
    @candidates [%{slug: "a", style: "s"}, %{slug: "b", style: "s"}]

    test "tolerates code fences and prose around the array" do
      text = "Sure!\n```json\n[{\"slug\":\"a\",\"safe\":true}]\n```"
      assert LLM.__parse_vet_verdicts__(text, @candidates).safe == ["a"]
    end

    test "hallucinated slugs are dropped from both axes" do
      text = ~s([{"slug":"a","safe":true},{"slug":"ghost","safe":true,"real_person":true}])
      assert LLM.__parse_vet_verdicts__(text, @candidates) == %{safe: ["a"], real_person: []}
    end

    test "missing entries and non-true verdicts fail closed" do
      assert LLM.__parse_vet_verdicts__(~s([{"slug":"a","safe":"yes"}]), @candidates).safe == []
      assert LLM.__parse_vet_verdicts__(~s([]), @candidates).safe == []
    end

    test "missing real_person field (old prompt shape) deletes nothing" do
      text = ~s([{"slug":"a","safe":true},{"slug":"b","safe":false}])
      assert LLM.__parse_vet_verdicts__(text, @candidates) == %{safe: ["a"], real_person: []}
    end

    test "garbage fails closed" do
      assert LLM.__parse_vet_verdicts__("not json", @candidates) == %{safe: [], real_person: []}
      assert LLM.__parse_vet_verdicts__(nil, @candidates) == %{safe: [], real_person: []}
    end
  end

  describe "Voices vetted persistence" do
    test "replace_generated defaults vetted to false and persists an explicit true" do
      {:ok, game} = Games.create_game(%{name: "Test"})

      :ok =
        Voices.replace_generated(game.id, [
          %{slug: "plain", label: "Plain", emoji: "🙂", style: "plain"},
          %{slug: "safe", label: "Safe", emoji: "✅", style: "safe", vetted: true}
        ])

      defs = Voices.game_voice_defs(game.id)
      assert %{vetted: false} = Enum.find(defs, &(&1.id == "g:plain"))
      assert %{vetted: true} = Enum.find(defs, &(&1.id == "g:safe"))
    end

    test "unvetted_generated/1 and mark_vetted/2 round-trip" do
      {:ok, game} = Games.create_game(%{name: "Test"})

      :ok =
        Voices.replace_generated(game.id, [
          %{slug: "one", label: "One", emoji: "1️⃣", style: "one"},
          %{slug: "two", label: "Two", emoji: "2️⃣", style: "two"}
        ])

      assert Voices.unvetted_generated(game.id) |> Enum.map(& &1.slug) |> Enum.sort() ==
               ["one", "two"]

      :ok = Voices.mark_vetted(game.id, ["two"])

      assert Voices.unvetted_generated(game.id) |> Enum.map(& &1.slug) == ["one"]
      assert %{vetted: true} = Voices.get_def("g:two", game.id)
    end

    test "drop_generated deletes only the flagged slugs" do
      {:ok, game} = Games.create_game(%{name: "Test"})

      :ok =
        Voices.replace_generated(game.id, [
          %{slug: "keeper", label: "Keeper", emoji: "🙂", style: "kept"},
          %{slug: "klaus", label: "Spirit of Klaus", emoji: "👻", style: "a designer's ghost"}
        ])

      :ok = Voices.drop_generated(game.id, ["klaus"])

      assert Voices.game_voice_defs(game.id) |> Enum.map(& &1.id) == ["g:keeper"]
    end

    test "a style change through replace_generated resets vetted" do
      {:ok, game} = Games.create_game(%{name: "Test"})

      :ok =
        Voices.replace_generated(game.id, [
          %{slug: "v", label: "V", emoji: "🙂", style: "old", vetted: true}
        ])

      :ok =
        Voices.replace_generated(game.id, [
          %{slug: "v", label: "V", emoji: "🙂", style: "new"}
        ])

      assert %{vetted: false} = Voices.get_def("g:v", game.id)
    end
  end

  defp mock_llm(fun) do
    Application.put_env(:rule_maven, :llm_mock, fun)
    on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
  end
end
