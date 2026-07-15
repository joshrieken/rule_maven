defmodule RuleMaven.LLM.PolarityTest do
  @moduledoc """
  Guards the pool against serving an INVERTED rule.

  Every case here is drawn from a live probe that actually broke the ask: the
  pool served "**Yes** — the robber can be placed on the desert hex" to
  "Can the robber NOT be placed on the desert hex?", and answered "No." to
  "Is a player prohibited from trading before rolling?".
  """
  use ExUnit.Case, async: true

  alias RuleMaven.LLM.Polarity

  describe "negative?/1" do
    test "plain negation" do
      assert Polarity.negative?("Can the robber NOT be placed on the desert hex?")
      assert Polarity.negative?("Can I never trade before rolling?")
      assert Polarity.negative?("Is a settlement not allowed on a harbor?")
    end

    test "contractions, however they are spelled" do
      assert Polarity.negative?("Can't I trade before rolling?")
      # Typographic apostrophe — the one a phone keyboard actually produces.
      assert Polarity.negative?("Can’t I trade before rolling?")
      assert Polarity.negative?("cant i trade before rolling")
    end

    test "the banned/forbidden family, which is negative without a negative word" do
      assert Polarity.negative?("Is it forbidden to put the robber on the desert?")
      assert Polarity.negative?("Is a player prohibited from trading before rolling?")
      assert Polarity.negative?("Is building on a harbor illegal?")
      assert Polarity.negative?("Am I unable to build here?")
    end

    test "positive questions are positive" do
      refute Polarity.negative?("Can the robber be placed on the desert hex?")
      refute Polarity.negative?("How many cards must be discarded on a 7?")
      refute Polarity.negative?("What are the loss conditions?")
    end

    test "word boundaries — a negation must not hide inside another word" do
      # "no" inside "north", "not" inside "notation"/"another", "cant" in "cantrip".
      refute Polarity.negative?("Can I build to the north?")
      refute Polarity.negative?("What is the notation on the board?")
      refute Polarity.negative?("Can I move to another hex?")
    end

    test "blank and nil are positive — an absent question cannot disagree" do
      refute Polarity.negative?(nil)
      refute Polarity.negative?("")
    end
  end

  describe "compatible?/2" do
    test "a negatively-asked question does NOT match a positive pooled entry" do
      # The exact live failure: this pair was served, and the answer was inverted.
      refute Polarity.compatible?(
               "Can the robber NOT be placed on the desert hex?",
               "Can the robber be placed on the desert hex?"
             )

      refute Polarity.compatible?(
               "Is it forbidden to put the robber on the desert?",
               "Can the robber be placed on the desert hex?"
             )

      refute Polarity.compatible?(
               "Is a player prohibited from trading before rolling?",
               "Can a player trade before rolling?"
             )
    end

    test "same polarity on both sides still matches — the guard must not break the pool" do
      assert Polarity.compatible?(
               "can i put the robber on the desert?",
               "Can the robber be placed on the desert hex?"
             )

      assert Polarity.compatible?(
               "Can the robber NOT be placed on a hex I own?",
               "Can the robber not be placed on an owned hex?"
             )
    end
  end

  describe "strip_inverted_lead/2" do
    test "drops the flippable lead on a negative question, keeping the rule" do
      # The live inversion: lead says the thing is allowed, the very next clause
      # says it is not. Dropping the lead leaves only the part that was correct.
      assert Polarity.strip_inverted_lead(
               "**No**, a player cannot trade before rolling for resource production.",
               "Is a player prohibited from trading before rolling?"
             ) == "A player cannot trade before rolling for resource production."
    end

    test "drops it whichever way the model was leaning — both runs converge" do
      q = "Is a player prohibited from trading before rolling?"

      yes_run = Polarity.strip_inverted_lead("**Yes**, a player is prohibited from trading.", q)
      no_run = Polarity.strip_inverted_lead("**No**, a player cannot trade before rolling.", q)

      refute yes_run =~ "Yes"
      refute no_run =~ "No,"
      assert yes_run == "A player is prohibited from trading."
      assert no_run == "A player cannot trade before rolling."
    end

    test "handles an unbolded lead too" do
      assert Polarity.strip_inverted_lead(
               "No, you cannot build a road through another player's road.",
               "Can I not build a road through another player's road?"
             ) == "You cannot build a road through another player's road."
    end

    test "a POSITIVE question keeps its lead — that is where Yes/No is load-bearing" do
      answer = "**No.** Trading before rolling is not permitted."

      assert Polarity.strip_inverted_lead(answer, "Can a player trade before rolling?") == answer
    end

    test "an answer with no lead word is untouched" do
      answer = "Trading is not permitted before the dice are rolled."

      assert Polarity.strip_inverted_lead(answer, "Is trading prohibited before rolling?") ==
               answer
    end

    test "a bare 'No'/'Yes' opening a SENTENCE is not a lead — stripping it flips the body" do
      # The old all-optional regex matched the "No " of "No trading..." and
      # stripped a correct body into its opposite.
      neg = "Isn't trading allowed before rolling?"

      for answer <- [
            "No trading is allowed before rolling.",
            "Nothing happens on a six.",
            "None of the players discard.",
            "Note that trading is banned.",
            "Yes you can trade."
          ] do
        assert Polarity.strip_inverted_lead(answer, neg) == answer
      end
    end

    test "bolded verdicts strip with punctuation inside the bold, synonyms included" do
      neg = "Isn't trading allowed?"

      assert Polarity.strip_inverted_lead("**No!** Never.", neg) == "Never."
      assert Polarity.strip_inverted_lead("**Yes.** Trading is allowed.", neg) == "Trading is allowed."
      assert Polarity.strip_inverted_lead("**Correct** — that is banned.", neg) == "That is banned."
    end

    test "negation words round 25: mustnt/nobody/nothing/neither/noone/neednt/aint" do
      for q <- [
            "Mustn't players discard half on a seven?",
            "Does nobody get resources when a seven is rolled?",
            "Do I get nothing from a hex the robber occupies?",
            "Can neither player build during the opponent's turn?",
            "Needn't I discard on a seven?",
            "Ain't I allowed to trade?"
          ] do
        assert Polarity.negative?(q), q
      end
    end

    test "negative-polarity PHRASES with no negative token: against the rules / out of bounds / off-limits / cheating" do
      for q <- [
            "Is moving twice against the rules?",
            "Is building out of bounds there?",
            "Is that spot off-limits for settlements?",
            "Is it cheating to look at the deck?"
          ] do
        assert Polarity.negative?(q), q
      end

      refute Polarity.negative?("Can I lean my card against the board?")
    end
  end
end
