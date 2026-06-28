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
end
