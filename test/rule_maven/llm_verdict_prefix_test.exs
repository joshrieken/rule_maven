defmodule RuleMaven.LLMVerdictPrefixTest do
  use ExUnit.Case, async: true

  alias RuleMaven.LLM

  # decode_answer strips a "**Yes** —" / "No." lead on an "info" verdict.
  # The separator class used to include a bare hyphen with no whitespace
  # requirement, so a hyphenated "No-..." word parsed as lead + separator.
  describe "hyphenated No-/Yes- leads are not verdict prefixes" do
    test "\"No-one may look\" keeps its meaning" do
      answer = "No-one may look at another player's cards until the round ends."
      assert LLM.__strip_verdict_prefix__(answer, "info") == answer
    end

    test "\"No-frills\" lead survives" do
      answer = "No-frills scoring applies whenever the advanced module is left out."
      assert LLM.__strip_verdict_prefix__(answer, "info") == answer
    end
  end

  describe "real verdict leads still strip" do
    test "em-dash lead" do
      assert LLM.__strip_verdict_prefix__(
               "**Yes** — you may discard one Item per Hit symbol rolled.",
               "info"
             ) == "You may discard one Item per Hit symbol rolled."
    end

    test "period lead" do
      assert LLM.__strip_verdict_prefix__(
               "No. The rulebook restricts trading to your own turn only.",
               "info"
             ) == "The rulebook restricts trading to your own turn only."
    end

    test "spaced hyphen lead" do
      assert LLM.__strip_verdict_prefix__(
               "Yes - you may move through your own pieces freely here.",
               "info"
             ) == "You may move through your own pieces freely here."
    end

    test "a non-info verdict is never stripped" do
      answer = "**Yes** — you may discard one Item per Hit symbol rolled."
      assert LLM.__strip_verdict_prefix__(answer, "rule") == answer
    end
  end
end
