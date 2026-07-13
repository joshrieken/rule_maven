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

  # The model occasionally omits "verdict" from its JSON (or emits a word
  # outside the fixed vocabulary). coerce_verdict/1 turned that into nil, and a
  # nil verdict renders as NO stamp at all — a clean "No, you cannot trade like
  # resources" shipped with no illegal badge. The answer's own Yes/No lead is an
  # unambiguous statement of legality, so use it rather than dropping the stamp.
  describe "verdict falls back to the answer's Yes/No lead" do
    defp verdict_for(json), do: LLM.decode_answer(json)[:verdict]

    test "a missing verdict on a No lead becomes illegal" do
      json = ~s({"answer": "**No** — you may not trade like resources.", "citations": []})
      assert verdict_for(json) == "illegal"
    end

    test "a missing verdict on a Yes lead becomes legal" do
      json = ~s({"answer": "Yes, a settlement may be built on the coast.", "citations": []})
      assert verdict_for(json) == "legal"
    end

    test "an unrecognized verdict word also falls back to the lead" do
      json = ~s({"verdict": "forbidden", "answer": "No. The robber must move.", "citations": []})
      assert verdict_for(json) == "illegal"
    end

    test "a missing verdict with no Yes/No lead stays nil" do
      # Nothing to infer from — inventing "info" here would stamp explanatory
      # answers that the model deliberately left unclassified.
      json = ~s({"answer": "Cities produce two resource cards.", "citations": []})
      assert verdict_for(json) == nil
    end

    test "an explicit verdict always wins over the lead" do
      # A real "info" verdict on a "what can counter X" answer that happens to
      # open with "Yes" must stay info — the fallback is for MISSING verdicts.
      json = ~s({"verdict": "info", "answer": "Yes, and also no.", "citations": []})
      assert verdict_for(json) == "info"
    end

    test "the refusal phrase is not mistaken for a legality lead" do
      json = ~s({"answer": "The rulebook does not cover this question.", "citations": []})
      assert verdict_for(json) == nil
    end
  end
end
