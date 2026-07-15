defmodule RuleMaven.LLM.AnswerFlippingTest do
  # The pool guard must see the CONTEXT-EXPANDED question, not only the raw
  # fragment the asker typed. A follow-up like "what about then?" carries no
  # facet on its own, but its expansion ("...trade AFTER rolling...") flips the
  # answer of a candidate about trading BEFORE rolling. The guard runs on both.
  use ExUnit.Case, async: true

  alias RuleMaven.LLM

  defp row(text), do: %{id: 1, canonical_question: text, cleaned_question: nil, question: nil}

  test "fires when only the context-expanded question conflicts with the candidate" do
    raw = "what about then?"
    expanded = "Can a player trade after rolling the dice?"
    candidate = "Can a player trade before rolling the dice?"

    # Guard sees only the raw fragment -> blind -> would serve the wrong rule.
    refute LLM.__answer_flipping__(raw, raw, row(candidate))

    # Guard sees the expansion -> the temporal flip is caught -> rejected.
    assert LLM.__answer_flipping__(raw, expanded, row(candidate))
  end

  test "still fires on a raw-only negation the expansion erased" do
    # Normalization strips the negation, so the raw question is the only place
    # the "forbidden" polarity survives. The guard must keep checking it.
    raw = "Is it forbidden to place the robber on the desert?"
    expanded = "Can the robber be placed on the desert?"
    candidate = "Can the robber be placed on the desert?"

    assert LLM.__answer_flipping__(raw, expanded, row(candidate))
  end

  test "a subject/object role reversal is rejected on the serve path" do
    # Identical bag, order flips the answer — the guard must reject (fall through
    # to a full-price ask), never serve. This holds whether the near-identical
    # entities are a typo or two genuinely similar unit names: rejecting is the
    # fail-safe direction in both cases.
    raw = "Does the archer beat the knight?"
    candidate = "Does the knight beat the archer?"

    assert LLM.__answer_flipping__(raw, raw, row(candidate))
  end

  test "compatible follow-up is served (no false rejection)" do
    raw = "and after that?"
    expanded = "Can a player trade after rolling the dice?"
    candidate = "May a player trade once the dice are rolled?"

    refute LLM.__answer_flipping__(raw, expanded, row(candidate))
  end
end
