defmodule RuleMaven.Extract.CleanCheckTest do
  use ExUnit.Case, async: true

  alias RuleMaven.Extract.CleanCheck

  @clean_prose """
  Each player draws five cards at the start of the game and keeps them hidden.
  On your turn you may play one card and then move your pawn up to three spaces.
  """

  @garbled """
  Each player draws five cards at the start of the game and keeps them hidden.
  ~~ %% §§ x7 qq zz ##" ]] [[ ø ø ø
  On your turn you may play one card and then move your pawn up to three spaces.
  """

  test "empty status accepts (blank page)" do
    assert CleanCheck.check("", "", :standard, :empty) == :accept
  end

  test "guard_fired is always suspect over" do
    assert CleanCheck.check(@clean_prose, "Each player draws.", :standard, :guard_fired) ==
             {:suspect, :over}
  end

  test "kept_raw accepts as-is regardless of content (legacy hard-guard revert)" do
    assert CleanCheck.check(@clean_prose, @clean_prose, :standard, :kept_raw) == :accept
  end

  test "unchanged on clean input accepts" do
    assert CleanCheck.check(@clean_prose, @clean_prose, :standard, :unchanged) == :accept
  end

  test "unchanged on junky input is suspect under" do
    assert CleanCheck.check(@garbled, @garbled, :standard, :unchanged) == {:suspect, :under}
  end

  test "cleaned output inside envelope with no garble accepts" do
    # ~11% shrink at standard (envelope allows up to 30%).
    cleaned = String.slice(@clean_prose, 0, round(String.length(@clean_prose) * 0.89))
    assert CleanCheck.check(@clean_prose, cleaned, :standard, :cleaned) == :accept
  end

  test "surviving garble lines are suspect under" do
    assert CleanCheck.check(@garbled, @garbled <> " tidied", :standard, :cleaned) ==
             {:suspect, :under}
  end

  test "huge shrink at light is suspect over" do
    cleaned = String.slice(@clean_prose, 0, round(String.length(@clean_prose) * 0.5))
    assert CleanCheck.check(@clean_prose, cleaned, :light, :cleaned) == {:suspect, :over}
  end

  test "under-shrink at aggressive is suspect under" do
    # Aggressive is meant to cut ≥10%; an output identical in size didn't cut.
    assert CleanCheck.check(@clean_prose, @clean_prose <> " ", :aggressive, :cleaned) ==
             {:suspect, :under}
  end

  test "both signals combine to :both" do
    # Garble survives AND shrink beyond light's 15% cap.
    out = "~~ %% §§ x7 qq zz ##\nshort"
    assert CleanCheck.check(@clean_prose, out, :light, :cleaned) == {:suspect, :both}
  end

  test "garble_lines counts low-wordish lines with enough tokens" do
    assert CleanCheck.garble_lines(@garbled) == 1
    assert CleanCheck.garble_lines(@clean_prose) == 0
  end
end
