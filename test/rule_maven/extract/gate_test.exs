defmodule RuleMaven.Extract.GateTest do
  use ExUnit.Case, async: true

  alias RuleMaven.Extract.Gate

  @prose """
  In every game of Summer Camp you compete for merit badges in various camp
  activities: adventure, arts and crafts, cooking, friendship, games, outdoors,
  or water sports. Choose what activities you want to play this round.
  """

  describe "clean_text_layer?/1" do
    test "trusts clear, wordish prose" do
      assert Gate.clean_text_layer?(@prose)
    end

    test "rejects empty / trivial / symbol-soup layers" do
      refute Gate.clean_text_layer?("")
      refute Gate.clean_text_layer?("12")
      refute Gate.clean_text_layer?("ASE Q YopM&y AcIPa s CE (HP FW? I)")
    end

    test "trusts real rulebook text whose wordish is dragged down by numbers/icons" do
      # Genuine born-digital rule text scores wordish ~0.77 (measured across 3
      # rulebooks) because numbers, one/two-letter words and card codes aren't
      # "wordish" — but pdftotext reads it perfectly. It must be trusted.
      text =
        "Gain 2 plants and 1 heat. Place a city tile on any available land " <>
          "area adjacent to another tile you own. Raise your terraform rating 1 step."

      assert Gate.wordish_ratio(text) < 0.85
      assert Gate.wordish_ratio(text) >= 0.75
      assert Gate.clean_text_layer?(text)
    end

    test "does not trust a short, wordish snippet — too little to validate structurally" do
      # Clean but tiny (< token floor): little signal, cheap to cross-check, so we
      # do not skip vision on it.
      refute Gate.clean_text_layer?("Choose your camp activities carefully before every round")
    end
  end

  describe "majority/2" do
    test "two of three reads agree → returns the richer of the agreeing pair" do
      a = "gain two plants and one heat then place a city tile"
      # b is the same content, slightly richer (a few more real words)
      b = "gain two plants and one heat then place a city tile on land"
      c = "wholly different garbled symbol soup xqz vvv"

      assert {:ok, ^b} = Gate.majority([a, b, c], 0.75)
    end

    test "no two reads agree → :none" do
      a = "gain two plants and one heat"
      b = "raise your terraform rating one step"
      c = "place a greenery tile beside another"

      assert :none = Gate.majority([a, b, c], 0.75)
    end

    test "two failed reads (both empty) do not settle the page as blank" do
      # A real read plus two failed re-reads ("" from a dead vision call) must
      # NOT let the two empty strings "agree" with each other and settle the
      # page as blank — that would silently drop the real content in `a`.
      a = "gain two plants and one heat then place a city tile on the land"

      assert :none = Gate.majority([a, "", ""], 0.75)
    end

    test "all reads failed (all empty) → :none, not a blank consensus" do
      # This never legitimately happens at T1 (assess/2 settles genuine blank
      # pages before majority/2 is ever called), so at this level every-read-
      # empty always means total read failure, not a blank page — don't vote.
      assert :none = Gate.majority(["", "", ""], 0.75)
    end
  end

  describe "majority/3 with exclude_pairs" do
    test "excludes a specified pair from voting" do
      # a and b would agree with each other, but that pair is the original T1
      # pair that already disagreed on a fuller test (coverage/wordish) — it
      # must not be allowed to settle T2a on its own, unsupported by any new
      # (higher-DPI) read.
      a = "gain two plants and one heat then place a city tile on the land"
      b = "gain two plants and one heat then place a city tile on the land today"
      c = "wholly different garbled symbol soup xqz vvv nowhere close to that"

      assert :none = Gate.majority([a, b, c], 0.75, exclude_pairs: [{0, 1}])
    end

    test "still finds agreement via a non-excluded pair" do
      a = "gain two plants and one heat then place a city tile on the land"
      b = "wholly different garbled symbol soup xqz vvv nowhere close to that"
      c = "gain two plants and one heat then place a city tile on the land also"

      assert {:ok, ^c} = Gate.majority([a, b, c], 0.75, exclude_pairs: [{0, 1}])
    end
  end

  describe "agreement/2 and coverage/2" do
    test "identical text → full agreement and coverage" do
      assert Gate.agreement(@prose, @prose) == 1.0
      assert Gate.coverage(@prose, @prose) == 1.0
    end

    test "both empty → agreement 1.0 (concur: no text)" do
      assert Gate.agreement("", "") == 1.0
      assert Gate.coverage("", "") == 1.0
    end

    test "one empty → zero agreement and coverage" do
      assert Gate.agreement(@prose, "") == 0.0
      assert Gate.coverage(@prose, "") == 0.0
    end

    test "a dropped half → coverage well below 1.0" do
      half = "In every game of Summer Camp you compete for merit badges"
      assert Gate.coverage(@prose, half) < 0.7
    end
  end

  describe "assess/2" do
    test "two concurring reads → agree, no escalation, high confidence" do
      a = @prose
      b = @prose <> " A minor difference."
      r = Gate.assess(a, b)
      assert r.agree?
      refute r.escalate?
      assert r.confidence > 0.8
    end

    test "divergent reads → escalate" do
      a = @prose
      b = "ASE Q YopM&y AcIPa s CE (HP FW? I) IN IK"
      r = Gate.assess(a, b)
      refute r.agree?
      assert r.escalate?
    end

    test "a silent drop (one reader missed a chunk) → escalate" do
      a = @prose
      b = "In every game of Summer Camp you compete for merit badges"
      r = Gate.assess(a, b)
      assert r.escalate?
    end

    test "both empty (blank/art page) → agree, no endless escalation" do
      r = Gate.assess("", "")
      assert r.agree?
      refute r.escalate?
    end
  end
end
