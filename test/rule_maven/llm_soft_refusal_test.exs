defmodule RuleMaven.LLMSoftRefusalTest do
  use ExUnit.Case, async: true

  alias RuleMaven.LLM

  # A model that phrases "not covered" in its own words used to defeat every
  # non-coverage gate — they all compared the answer to the boilerplate refusal
  # string. The result a player saw (2026-09-06): prose reading "The rulebook
  # does not recommend a specific number of Monsters to play against." stamped
  # 📖 IN THE RULES over a real citation, with neither escalation rung ever
  # firing to go looking for the passage that does answer it.
  describe "soft_refusal?/1 recognises non-coverage in the model's own words" do
    test "the reported answer" do
      assert LLM.__soft_refusal__(
               "The rulebook does not recommend a specific number of Monsters to play against. It suggests certain Monsters based on player experience, but not a quantity."
             )
    end

    test "contraction form" do
      assert LLM.__soft_refusal__("The rulebook doesn't specify a hand limit.")
    end

    test "plural subject" do
      assert LLM.__soft_refusal__("The rules do not state how ties are broken.")
    end

    test "rules-are-silent form" do
      assert LLM.__soft_refusal__("The rules are silent on stacking two Powers.")
    end

    test "bolded lead" do
      assert LLM.__soft_refusal__("**The rulebook does not mention** rotating tiles.")
    end
  end

  describe "soft_refusal?/1 leaves real answers alone" do
    # The single most important non-match: a permission ruling. "does not allow"
    # is an ANSWER about legality, not a claim that the book is silent — reading
    # it as a refusal would suppress a correct ❌ NOT ALLOWED stamp.
    test "permission ruling is not a refusal" do
      refute LLM.__soft_refusal__("The rulebook does not allow trading on another player's turn.")
      refute LLM.__soft_refusal__("The rules do not permit moving through an occupied space.")
    end

    test "non-coverage buried mid-answer is not a lead refusal" do
      refute LLM.__soft_refusal__(
               "You may move two spaces. The rulebook does not specify what happens if you stop early."
             )
    end

    test "a substantive answer is untouched" do
      refute LLM.__soft_refusal__("Two. Play against the Displacer Beast and the Beholder.")
    end

    test "blank" do
      refute LLM.__soft_refusal__("")
      refute LLM.__soft_refusal__(nil)
    end
  end

  # The stamp is what a skimming player trusts, so it must not claim coverage
  # over prose that denies it. `info` means "not a yes/no legality question" —
  # it says nothing about coverage, which is why it survived until now.
  describe "a soft refusal corrects the verdict stamp" do
    test "info becomes silent" do
      assert LLM.__verdict_from_lead__(
               "info",
               "The rulebook does not recommend a specific number of Monsters to play against."
             ) == "silent"
    end

    test "nil becomes silent" do
      assert LLM.__verdict_from_lead__(
               nil,
               "The rulebook does not specify a maximum hand size."
             ) == "silent"
    end

    test "an explicit legality verdict still wins over a non-coverage lead" do
      # "does not allow" is not a soft refusal, so illegal survives intact.
      assert LLM.__verdict_from_lead__(
               "illegal",
               "The rulebook does not allow trading on another player's turn."
             ) == "illegal"
    end

    test "ordinary info answers keep their stamp" do
      assert LLM.__verdict_from_lead__(
               "info",
               "Two. Play against the Displacer Beast and the Beholder."
             ) == "info"
    end
  end
end
