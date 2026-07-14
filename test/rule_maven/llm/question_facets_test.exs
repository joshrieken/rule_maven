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

      # Ratios fall out of the digit scan: {4,1} vs {2,1}.
      refute Facets.compatible?(
               "Can I trade with the bank at 2:1?",
               "Can I trade with the bank at 4:1?"
             )

      refute Facets.compatible?("Can a player roll only two dice?", "Can a player roll only one die?")
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
  end
end
