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

  test "a short passage must appear on the page it cites, not just somewhere" do
    # "tokens" is real text — but it lives on page 7, and the model cited page 3.
    # Page 3 exists in context, so a bare page-existence check called this
    # grounded and pooled the answer.
    refute Citations.valid?("tokens", 3, @chunks)
    assert Citations.valid?("tokens", 7, @chunks)
  end

  test "a fabricated short passage cannot ride a real page number" do
    # The exact shape of the hole: invented quote, plausible page, both "check out".
    refute Citations.valid?("Draw one card", 3, @chunks)
    refute Citations.valid?("Yes", 7, @chunks)
  end

  describe "source-scoped validation" do
    @rulebook %{
      label: "Core rules",
      content: "[Page 5]\nThe player with the most banners wins the region."
    }
    @faq %{label: "Official FAQ", content: "[Page 2]\nTies award the region to no one."}

    test "cited page must exist in the cited source" do
      # Page 5 exists in Core rules, not in the FAQ.
      assert Citations.valid?("most banners wins the region", 5, [@rulebook, @faq], "Core rules")

      refute Citations.valid?(
               "most banners wins the region",
               5,
               [@rulebook, @faq],
               "Official FAQ"
             )
    end

    test "unknown source label falls back to pooled validation" do
      assert Citations.valid?("most banners wins the region", 5, [@rulebook, @faq], "Nonexistent")
    end

    test "nil source keeps legacy pooled behavior" do
      assert Citations.valid?("most banners wins the region", 5, [@rulebook, @faq], nil)
    end
  end

  describe "canonical_source/2" do
    @rulebook %{
      label: "Core rules",
      content: "[Page 5]\nThe player with the most banners wins the region."
    }
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

  describe "valid_citations/2" do
    @chunks [
      "[Page 3] Each player draws three cards at the start of their turn.",
      "[Page 7] Scoring happens at the end of the round, summing all face-up tokens."
    ]

    test "keeps only the grounded entries, preserving order" do
      citations = [
        %{
          "quote" => "draws three cards at the start of their turn",
          "page" => 3,
          "source" => nil
        },
        %{"quote" => "the dragon devours two villages each dawn", "page" => 3, "source" => nil},
        %{"quote" => "summing all face-up tokens", "page" => 7, "source" => nil}
      ]

      assert Citations.valid_citations(citations, @chunks) == [
               %{
                 "quote" => "draws three cards at the start of their turn",
                 "page" => 3,
                 "source" => nil
               },
               %{"quote" => "summing all face-up tokens", "page" => 7, "source" => nil}
             ]
    end

    test "empty input yields empty output" do
      assert Citations.valid_citations([], @chunks) == []
    end

    test "all-ungrounded input yields empty output" do
      citations = [%{"quote" => "invented nonsense", "page" => 99, "source" => nil}]
      assert Citations.valid_citations(citations, @chunks) == []
    end

    test "non-list input yields empty output" do
      assert Citations.valid_citations(nil, @chunks) == []
    end
  end

  describe "suspicious?/2" do
    test "flags a trigger word not present in the cited quotes" do
      quotes = ["Move the Terror Marker up one space on the Terror Level Track."]

      answer =
        "Defeating a Hero or Citizen raises Terror. Defeating a Monster lowers it."

      assert Citations.suspicious?(answer, quotes)
    end

    test "does not flag a trigger word that's already in the quote" do
      quotes = [
        "If a Hero is defeated, move the Terror Marker up one space unless a Citizen was already lost."
      ]

      answer = "Terror moves up one space unless a Citizen was already lost."

      refute Citations.suspicious?(answer, quotes)
    end

    test "flags an answer disproportionately longer than its citations" do
      quotes = ["Draw three cards."]

      answer =
        String.duplicate("This is extra elaboration not found in the source text. ", 10)

      assert Citations.suspicious?(answer, quotes)
    end

    test "does not flag a plain answer with no trigger words and reasonable length" do
      quotes = ["Each player draws three cards at the start of their turn."]
      answer = "Each player draws three cards at the start of their turn."

      refute Citations.suspicious?(answer, quotes)
    end

    test "refusal text with no citations is never flagged" do
      refute Citations.suspicious?("The rulebook does not cover this question.", [])
    end

    test "nil answer is never flagged" do
      refute Citations.suspicious?(nil, ["some quote"])
    end
  end

  describe "suspicion/2" do
    test "names the keyword trigger" do
      quotes = ["Move the Terror Marker up one space on the Terror Level Track."]
      answer = "Defeating a Hero or Citizen raises Terror. Defeating a Monster lowers it."

      assert Citations.suspicion(answer, quotes) == :keyword
    end

    test "names the length-ratio trigger" do
      quotes = ["Draw three cards."]

      answer =
        String.duplicate("This is extra elaboration not found in the source text. ", 10)

      assert Citations.suspicion(answer, quotes) == :length_ratio
    end

    test "keyword wins when both triggers fire" do
      quotes = ["Draw three cards."]

      answer =
        "You cannot draw more. " <>
          String.duplicate("This is extra elaboration not found in the source text. ", 10)

      assert Citations.suspicion(answer, quotes) == :keyword
    end

    test "returns nil for a grounded answer" do
      quotes = ["Each player draws three cards at the start of their turn."]
      assert Citations.suspicion("Each player draws three cards.", quotes) == nil
    end

    test "names the numeric trigger for a quantity no source chunk mentions" do
      # Short and confident, so the length ratio can't fire; no trigger word
      # either. Before the numeric check this reached the user unexamined.
      quotes = ["Each player takes actions during their turn."]
      sources = ["[Page 2] Each player takes actions during their turn."]
      assert Citations.suspicion("You get 3 action points per turn.", quotes, sources) == :numeric
    end

    test "a number in the chunk but not the cited quote is NOT suspicious" do
      # Quotes are condensed; judging numbers against them would fire the critic
      # on a large fraction of correct answers.
      quotes = ["Each player draws cards at the start of their turn."]
      sources = ["[Page 3] Each player draws 3 cards at the start of their turn."]
      assert Citations.suspicion("Draw 3 cards.", quotes, sources) == nil
    end

    test "digits and spelled numbers are the same quantity" do
      assert Citations.suspicion("Draw 3 cards.", [], ["Each player draws three cards."]) == nil
      assert Citations.suspicion("Draw three cards.", [], ["Each player draws 3 cards."]) == nil
    end

    test "a wrong number is caught even when the source has a number" do
      sources = ["[Page 3] Each player draws three cards."]
      assert Citations.suspicion("Each player draws 5 cards.", [], sources) == :numeric
    end

    test "with no sources the numeric trigger stays silent" do
      # Nothing to judge against — firing here would flag every answer that
      # happens to mention a number.
      assert Citations.suspicion("You move 4 spaces.", []) == nil
    end

    test "a [Page N] marker's digit cannot ground a fabricated number" do
      # normalize/1 strips [page N] before the digit scan. If that ever stops
      # being true, the page marker's own digits would silently ground any
      # answer that happens to state the same number, reopening the hole the
      # :numeric trigger exists to close.
      sources = ["[Page 3] Each player takes actions during their turn."]
      assert Citations.suspicion("You get 3 action points per turn.", [], sources) == :numeric
    end
  end
end
