defmodule RuleMaven.LLM.QuestionFacetsTest do
  @moduledoc """
  Guards the pool against serving one question's answer to a DIFFERENT question.

  Every rejection case here is a pair that actually landed a false DIRECT pool hit
  against real pooled rows — no LLM call, no critic, nothing else looking. The
  acceptance cases are the other half of the job: this guard sits in front of the
  only free answer in the system, so over-blocking quietly bills every paraphrase
  at full price.
  """
  use ExUnit.Case, async: true

  alias RuleMaven.LLM.QuestionFacets, as: Facets

  describe "rejects the flips that were actually served" do
    test "before/after — the worst one" do
      # Live: served "**No.** Trading before rolling is not permitted." to this.
      # Trading after rolling is what a player does every turn.
      refute Facets.compatible?(
               "Can a player trade after rolling?",
               "Can a player trade before rolling?"
             )

      assert Facets.conflict(
               "Can a player trade after rolling?",
               "Can a player trade before rolling?"
             ) == :temporal

      refute Facets.compatible?(
               "Is the robber moved before discarding on a 7?",
               "Is the robber moved after discarding on a 7?"
             )
    end

    test "may/must — permission served for an obligation" do
      # Live: "Must I move the robber?" -> "Yes, the robber CAN be moved."
      refute Facets.compatible?(
               "Must I move the robber when I play a knight?",
               "Can the robber be moved when a Knight card is played?"
             )

      assert Facets.conflict(
               "Must I move the robber when I play a knight?",
               "Can the robber be moved when a Knight card is played?"
             ) == :modal
    end

    test "more/fewer" do
      refute Facets.compatible?(
               "Do I discard when I have fewer than seven cards?",
               "Do I discard when I have more than seven cards?"
             )

      assert Facets.conflict(
               "Do I discard when I have fewer than seven cards?",
               "Do I discard when I have more than seven cards?"
             ) == :comparative
    end

    test "block/allow" do
      refute Facets.compatible?(
               "Does the robber allow resource production on the hex it occupies?",
               "Does the robber block resource production on an empty hex?"
             )
    end

    test "numbers — the rule IS the number" do
      refute Facets.compatible?(
               "How many cards must be discarded on an 8?",
               "How many cards must be discarded on a 7?"
             )

      assert Facets.conflict(
               "How many cards must be discarded on an 8?",
               "How many cards must be discarded on a 7?"
             ) == :number

      refute Facets.compatible?(
               "Do I discard if I have more than 9 cards?",
               "Do I discard if I have more than 7 cards?"
             )

      # A DIFFERENT ratio falls out of the digit scan: {4,1} vs {2,1}.
      refute Facets.compatible?(
               "Can I trade with the bank at 2:1?",
               "Can I trade with the bank at 4:1?"
             )

      # A REVERSED ratio has the same digits, so the set check passes it — the
      # colon-ratio order check is what catches 2:1 (give 2 get 1) vs 1:2.
      refute Facets.compatible?(
               "Can I trade with the bank at 2:1?",
               "Can I trade with the bank at 1:2?"
             )

      assert Facets.conflict(
               "Can I trade with the bank at 2:1?",
               "Can I trade with the bank at 1:2?"
             ) == :ratio

      # Same ratio, reworded around it, still matches.
      assert Facets.compatible?(
               "Is the harbor rate 3:1?",
               "Can I trade at 3:1 with a generic harbor?"
             )

      # A rewrite may drop a ratio premise but never reverse it.
      refute Facets.preserved_in_rewrite?(
               "At a 2:1 harbor can I trade?",
               "Can I trade at a 1:2 harbor?"
             )

      refute Facets.compatible?("Can a player roll only two dice?", "Can a player roll only one die?")
    end

    test "same/different — a single-token antonym that stays 0.97 on the embedding" do
      # Live: "Can the robber be placed on the same hex?" is a real pooled row,
      # so "...a different hex?" false-hit it and served the opposite.
      refute Facets.compatible?(
               "Can the robber be placed on a different hex?",
               "Can the robber be placed on the same hex?"
             )

      assert Facets.conflict(
               "Can the robber be placed on a different hex?",
               "Can the robber be placed on the same hex?"
             ) == :identity

      # "another" and "different" are BOTH the different-pole, so a real
      # paraphrase off the pooled "another settlement" survives.
      assert Facets.compatible?(
               "two spaces from another settlement",
               "two spaces from a different settlement"
             )
    end

    test "gain/lose — the value direction inverts the answer" do
      refute Facets.compatible?(
               "Do I gain a victory point for the longest road?",
               "Do I lose a victory point for the longest road?"
             )

      assert Facets.conflict(
               "Do I win if I reach ten points?",
               "Do I lose if I reach ten points?"
             ) == :value_direction
    end

    test "include/exclude — whether a rule counts or ignores something" do
      refute Facets.compatible?(
               "Does the longest road include roads broken by a settlement?",
               "Does the longest road exclude roads broken by a settlement?"
             )

      refute Facets.compatible?(
               "Does the longest road count broken segments?",
               "Does the longest road ignore broken segments?"
             )
    end

    test "open/closed — a narrow state pair, observed at 0.94" do
      refute Facets.compatible?(
               "Is trading open before I roll?",
               "Is trading closed before I roll?"
             )
    end

    test "negation is still gated (delegated to Polarity)" do
      refute Facets.compatible?(
               "Can the robber NOT be placed on the desert hex?",
               "Can the robber be placed on the desert hex?"
             )

      assert Facets.conflict(
               "Is it forbidden to trade before rolling?",
               "Can a player trade before rolling?"
             ) == :negation
    end
  end

  describe "preserved_in_rewrite?/2 — the normalizer must not snap a question onto its neighbour" do
    test "rejects a rewrite that crosses an answer-deciding axis" do
      # The nearest canonical question to this one IS its opposite, and the
      # normalizer is handed the nearest canonicals as hints.
      refute Facets.preserved_in_rewrite?(
               "Can a player trade after rolling?",
               "Can a player trade before rolling?"
             )

      refute Facets.preserved_in_rewrite?(
               "Must I move the robber?",
               "Can the robber be moved?"
             )

      refute Facets.preserved_in_rewrite?(
               "Is it forbidden to trade before rolling?",
               "Can a player trade before rolling?"
             )
    end

    test "a number may be DROPPED as a premise but never introduced or swapped" do
      # Legitimate: the 8 is a premise, and canonicalizing drops it.
      assert Facets.preserved_in_rewrite?(
               "If I roll a 7 and I have 8 cards, how many do I discard?",
               "How many cards must be discarded on a 7?"
             )

      # Not legitimate: this invents the very fact in dispute.
      refute Facets.preserved_in_rewrite?(
               "How many cards must be discarded on an 8?",
               "How many cards must be discarded on a 7?"
             )

      refute Facets.preserved_in_rewrite?(
               "How many cards do I discard?",
               "How many cards must be discarded on a 7?"
             )
    end

    test "an ordinary tidy-up survives" do
      assert Facets.preserved_in_rewrite?(
               "can i stick the robber on the desert lol",
               "Can the robber be placed on the desert hex?"
             )

      assert Facets.preserved_in_rewrite?(
               "how many cards do i toss when someone rolls a 7?",
               "How many cards must be discarded on a 7?"
             )
    end
  end

  describe "still lets real paraphrases through — the pool must keep working" do
    test "a reworded question with the same facets matches" do
      assert Facets.compatible?(
               "how many cards do i toss when someone rolls a 7?",
               "How many cards must be discarded on a 7?"
             )

      assert Facets.compatible?(
               "is trading allowed before you roll?",
               "Can a player trade before rolling?"
             )

      assert Facets.compatible?(
               "can i stick the robber on the desert?",
               "Can the robber be placed on the desert hex?"
             )
    end

    test "spelled and written numbers are the same number" do
      assert Facets.compatible?(
               "Do I discard with more than seven cards?",
               "Do I discard with more than 7 cards?"
             )
    end

    test "an axis only decides when BOTH sides name it" do
      # "must" vs silence is not a disagreement — the second question simply does
      # not raise obligation. Blocking here would cost a hit and learn nothing.
      assert Facets.compatible?(
               "How many cards must be discarded on a 7?",
               "How many cards do I discard on a 7?"
             )

      # Same for numbers: a question that mentions none is not disputing them.
      assert Facets.compatible?(
               "What are the rules for the robber?",
               "What are the robber rules?"
             )
    end

    test "same side of an axis, different word, still matches" do
      assert Facets.compatible?(
               "Is a player permitted to trade prior to rolling?",
               "Can a player trade before rolling?"
             )
    end

    test "the new antonym axes only fire when BOTH sides name a pole" do
      # "win" on one side, neither win nor lose on the other — not a dispute.
      assert Facets.compatible?(
               "Do I win at ten victory points?",
               "How do I reach ten victory points?"
             )

      # "same" with no different-pole word opposite it.
      assert Facets.compatible?(
               "Can the robber stay on the same hex?",
               "Can the robber remain where it is?"
             )

      # "count/include" with no exclude-pole opposite it.
      assert Facets.compatible?(
               "Does the longest road count broken segments?",
               "How is the longest road measured?"
             )
    end
  end
end
