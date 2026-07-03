defmodule RuleMaven.Games.CitationsTest do
  use ExUnit.Case, async: true

  alias RuleMaven.Games.Citations

  @chunks [
    "[Page 3] Each player draws three cards at the start of their turn.",
    "[Page 7] Scoring happens at the end of the round, summing all face-up tokens."
  ]

  test "grounded passage + matching page is valid" do
    assert Citations.valid?("draws three cards at the start of their turn", 3, @chunks)
  end

  test "grounded passage alone (no page) is valid" do
    assert Citations.valid?("summing all face-up tokens", nil, @chunks)
  end

  test "correct page alone (no checkable passage) is valid" do
    assert Citations.valid?(nil, 7, @chunks)
  end

  test "hallucinated passage is invalid even with a real page" do
    refute Citations.valid?("the dragon devours two villages each dawn", 3, @chunks)
  end

  test "fabricated page is invalid even with no passage" do
    refute Citations.valid?(nil, 42, @chunks)
  end

  test "passage grounded but page fabricated is invalid" do
    refute Citations.valid?("draws three cards", 42, @chunks)
  end

  test "no citation at all is invalid" do
    refute Citations.valid?(nil, nil, @chunks)
    refute Citations.valid?("", nil, @chunks)
  end

  test "no source context cannot ground anything" do
    refute Citations.valid?("draws three cards", 3, [])
    refute Citations.valid?("draws three cards", 3, nil)
  end

  test "too-short passage can't ground alone but a valid page rescues it" do
    refute Citations.valid?("turn", nil, @chunks)
    assert Citations.valid?("turn", 3, @chunks)
  end

  describe "source-scoped validation" do
    @rulebook %{label: "Core rules", content: "[Page 5]\nThe player with the most banners wins the region."}
    @faq %{label: "Official FAQ", content: "[Page 2]\nTies award the region to no one."}

    test "cited page must exist in the cited source" do
      # Page 5 exists in Core rules, not in the FAQ.
      assert Citations.valid?("most banners wins the region", 5, [@rulebook, @faq], "Core rules")
      refute Citations.valid?("most banners wins the region", 5, [@rulebook, @faq], "Official FAQ")
    end

    test "unknown source label falls back to pooled validation" do
      assert Citations.valid?("most banners wins the region", 5, [@rulebook, @faq], "Nonexistent")
    end

    test "nil source keeps legacy pooled behavior" do
      assert Citations.valid?("most banners wins the region", 5, [@rulebook, @faq], nil)
    end
  end

  describe "canonical_source/2" do
    @rulebook %{label: "Core rules", content: "[Page 5]\nThe player with the most banners wins the region."}
    @faq %{label: "Official FAQ", content: "[Page 2]\nTies award the region to no one."}

    test "mixed-case match returns the chunk's canonical label" do
      assert Citations.canonical_source("core RULES", [@rulebook, @faq]) == "Core rules"
    end

    test "exact-case match returns the canonical label" do
      assert Citations.canonical_source("Official FAQ", [@rulebook, @faq]) == "Official FAQ"
    end

    test "hallucinated label with no match returns nil" do
      assert Citations.canonical_source("Errata Sheet", [@rulebook, @faq]) == nil
    end

    test "nil cited_source returns nil" do
      assert Citations.canonical_source(nil, [@rulebook, @faq]) == nil
    end

    test "no source context returns nil" do
      assert Citations.canonical_source("Core rules", []) == nil
      assert Citations.canonical_source("Core rules", nil) == nil
    end

    test "accepts plain-string chunks (no label) and returns nil" do
      assert Citations.canonical_source("Core rules", ["[Page 1]\nsome text"]) == nil
    end
  end
end
