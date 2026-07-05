defmodule RuleMaven.VoicesTest do
  use RuleMaven.DataCase

  alias RuleMaven.{Games, Repo, Voices}
  alias RuleMaven.Voices.{AnswerVoice, GameVoice}

  defp game, do: elem(Games.create_game(%{name: "V #{System.unique_integer([:positive])}"}), 1)

  defp question(game) do
    {:ok, q} = Games.log_question(%{game_id: game.id, question: "q", answer: "a"})
    q
  end

  describe "for_game / resolution" do
    test "globals are always present and neutral stays first" do
      g = game()
      defs = Voices.for_game(g)
      assert hd(defs).id == "neutral"
      ids = Enum.map(defs, & &1.id)
      assert "pirate" in ids
    end

    test "generated voices are appended and namespaced g:<slug>" do
      g = game()

      :ok =
        Voices.replace_generated(g.id, [
          %{slug: "herald", label: "Woodland Herald", emoji: "🦉", style: "a courtly herald"}
        ])

      defs = Voices.for_game(g)
      gen = Enum.find(defs, &(&1.id == "g:herald"))
      assert gen.label == "Woodland Herald"
      # globals still there, generated comes after them
      assert Enum.find(defs, &(&1.id == "pirate"))
    end

    test "valid?/2 covers globals and the game's own generated voices only" do
      g = game()
      other = game()

      :ok =
        Voices.replace_generated(g.id, [%{slug: "herald", label: "H", emoji: "🦉", style: "x"}])

      assert Voices.valid?("pirate", g)
      assert Voices.valid?("g:herald", g)
      refute Voices.valid?("g:herald", other)
      refute Voices.valid?("g:nope", g)
    end
  end

  describe "loading_phrases/2" do
    test "returns a non-empty list for neutral (generic pool only)" do
      g = game()
      phrases = Voices.loading_phrases("neutral", g)
      assert is_list(phrases) and phrases != []
      assert Enum.all?(phrases, &is_binary/1)
    end

    test "returns a non-empty list for an unknown voice (generic pool only)" do
      g = game()
      assert Voices.loading_phrases("does-not-exist", g) != []
    end

    test "a built-in persona's own phrases are returned exclusively, no generic mixed in" do
      g = game()
      phrases = Voices.loading_phrases("pirate", g)
      pirate_own = Voices.get_def("pirate").loading

      assert phrases == pirate_own
      refute "Reticulating splines…" in phrases
    end

    test "neutral still uses only the generic pool (no own phrases defined)" do
      g = game()
      assert Voices.loading_phrases("neutral", g) == Voices.loading_phrases("neutral", g)
      # neutral has no `loading:` entry in @voices, so it must still fall back:
      assert "Reticulating splines…" in Voices.loading_phrases("neutral", g)
    end

    test "de-duplicates phrases" do
      g = game()
      phrases = Voices.loading_phrases("pirate", g)
      assert phrases == Enum.uniq(phrases)
    end

    test "each built-in persona has a sizeable own phrase set (>= 15)" do
      for id <- ~w(lawyer pirate robot coach) do
        own = Voices.get_def(id).loading
        assert length(own) >= 15, "#{id} has only #{length(own)} loading phrases"
        assert own == Enum.uniq(own), "#{id} has duplicate loading phrases"
      end
    end
  end

  describe "loading_phrases/2 for generated voices" do
    test "generated voice's own stored phrases are returned exclusively, no generic mixed in" do
      g = game()

      :ok =
        Voices.replace_generated(g.id, [
          %{
            slug: "herald",
            label: "Woodland Herald",
            emoji: "🦉",
            style: "a courtly herald",
            loading_phrases: ["Sounding the horn…", "Unrolling the scroll…"]
          }
        ])

      phrases = Voices.loading_phrases("g:herald", g)
      assert phrases == ["Sounding the horn…", "Unrolling the scroll…"]
      refute "Reticulating splines…" in phrases
    end

    test "generated voice without loading_phrases falls back to generic only" do
      g = game()

      :ok =
        Voices.replace_generated(g.id, [
          %{slug: "plain-gen", label: "Plain Gen", emoji: "🙂", style: "a plain narrator"}
        ])

      phrases = Voices.loading_phrases("g:plain-gen", g)
      assert phrases != []
      assert "Reticulating splines…" in phrases
    end
  end

  describe "store_direct/3" do
    test "caches content without calling the LLM, and Voices.get/2 returns it" do
      g = game()
      q = question(g)

      assert :ok = Voices.store_direct(q.id, "pirate", "Arr, that be the rule.")
      assert Voices.get(q.id, "pirate") == "Arr, that be the rule."
    end

    test "a second store_direct for the same (question, voice) is a no-op (first write wins)" do
      g = game()
      q = question(g)

      assert :ok = Voices.store_direct(q.id, "pirate", "First.")
      assert :ok = Voices.store_direct(q.id, "pirate", "Second.")
      assert Voices.get(q.id, "pirate") == "First."
    end
  end

  describe "replace_generated stability" do
    test "unchanged style and label keeps the row id and any cached restyles" do
      g = game()
      q = question(g)

      :ok =
        Voices.replace_generated(g.id, [
          %{slug: "herald", label: "H", emoji: "🦉", style: "courtly"}
        ])

      row1 = Repo.get_by!(GameVoice, game_id: g.id, slug: "herald")

      # A paid-for restyle is cached under the namespaced id.
      Repo.insert!(%AnswerVoice{question_log_id: q.id, voice: "g:herald", content: "hark!"})

      # Re-run with the SAME style and label — slug stable, cache preserved.
      # Only the emoji changed, which isn't part of the persona's identity.
      :ok =
        Voices.replace_generated(g.id, [
          %{slug: "herald", label: "H", emoji: "🦅", style: "courtly"}
        ])

      row2 = Repo.get_by!(GameVoice, game_id: g.id, slug: "herald")
      assert row1.id == row2.id
      assert row2.emoji == "🦅"
      assert Voices.get(q.id, "g:herald") == "hark!"
    end

    test "changed label alone drops that voice's cached restyles" do
      g = game()
      q = question(g)

      :ok =
        Voices.replace_generated(g.id, [
          %{slug: "herald", label: "H", emoji: "🦉", style: "courtly"}
        ])

      Repo.insert!(%AnswerVoice{question_log_id: q.id, voice: "g:herald", content: "hark!"})

      # Slug reused with the SAME style text but a different label — this can
      # happen if a regenerated persona's style prose happens to match the old
      # one; the label is the user-visible identity, so a change there must
      # still invalidate the cache even though `style` is byte-identical.
      :ok =
        Voices.replace_generated(g.id, [
          %{slug: "herald", label: "Herald II", emoji: "🦉", style: "courtly"}
        ])

      assert Voices.get(q.id, "g:herald") == nil
    end

    test "changed style drops that voice's cached restyles" do
      g = game()
      q = question(g)

      :ok =
        Voices.replace_generated(g.id, [
          %{slug: "herald", label: "H", emoji: "🦉", style: "courtly"}
        ])

      Repo.insert!(%AnswerVoice{question_log_id: q.id, voice: "g:herald", content: "hark!"})

      :ok =
        Voices.replace_generated(g.id, [
          %{slug: "herald", label: "H", emoji: "🦉", style: "GRUFF now"}
        ])

      assert Voices.get(q.id, "g:herald") == nil
    end

    test "vanished voice is deleted and its restyles cleared" do
      g = game()
      q = question(g)

      :ok =
        Voices.replace_generated(g.id, [%{slug: "herald", label: "H", emoji: "🦉", style: "x"}])

      Repo.insert!(%AnswerVoice{question_log_id: q.id, voice: "g:herald", content: "hark!"})

      :ok = Voices.replace_generated(g.id, [%{slug: "rogue", label: "R", emoji: "🗡️", style: "y"}])
      refute Repo.get_by(GameVoice, game_id: g.id, slug: "herald")
      assert Voices.get(q.id, "g:herald") == nil
      assert Repo.get_by(GameVoice, game_id: g.id, slug: "rogue")
    end
  end

  describe "popularity_rank" do
    test "persists popularity_rank and orders game_voice_defs by it ascending" do
      g = game()

      :ok =
        Voices.replace_generated(g.id, [
          %{slug: "c", label: "C", emoji: "🙂", style: "x", popularity_rank: 3},
          %{slug: "a", label: "A", emoji: "🙂", style: "x", popularity_rank: 1},
          %{slug: "b", label: "B", emoji: "🙂", style: "x", popularity_rank: 2}
        ])

      gen_ids =
        Voices.for_game(g)
        |> Enum.filter(&String.starts_with?(&1.id, "g:"))
        |> Enum.map(& &1.id)

      assert gen_ids == ["g:a", "g:b", "g:c"]
    end

    test "changing only popularity_rank does not clear cached restyles" do
      g = game()
      q = question(g)

      :ok =
        Voices.replace_generated(g.id, [
          %{slug: "herald", label: "H", emoji: "🦉", style: "courtly", popularity_rank: 5}
        ])

      Repo.insert!(%AnswerVoice{question_log_id: q.id, voice: "g:herald", content: "hark!"})

      :ok =
        Voices.replace_generated(g.id, [
          %{slug: "herald", label: "H", emoji: "🦉", style: "courtly", popularity_rank: 1}
        ])

      row = Repo.get_by!(GameVoice, game_id: g.id, slug: "herald")
      assert row.popularity_rank == 1
      assert Voices.get(q.id, "g:herald") == "hark!"
    end

    test "missing popularity_rank does not crash replace_generated" do
      g = game()

      assert :ok =
               Voices.replace_generated(g.id, [
                 %{slug: "plain", label: "Plain", emoji: "🙂", style: "x"}
               ])

      row = Repo.get_by!(GameVoice, game_id: g.id, slug: "plain")
      assert row.popularity_rank == nil
    end
  end

  describe "__plausible_restyle__/2 (dropped-answer guard)" do
    @answer "During a turn the active player may play any cards, buy from the display, then discard, draw, and pass to the next player in clockwise order."

    test "rejects a stub that dropped the answer" do
      refute Voices.__plausible_restyle__("Request received. Awaiting resolution.", @answer)
    end

    test "accepts a same-length in-character restyle" do
      styled =
        "Attention campers! On your turn you may play any cards, buy from the display, then discard, draw, and pass clockwise to the next camper."

      assert Voices.__plausible_restyle__(styled, @answer)
    end

    test "tolerates light compression (>= 50%)" do
      half = String.slice(@answer, 0, round(String.length(@answer) * 0.6))
      assert Voices.__plausible_restyle__(half, @answer)
    end
  end
end
