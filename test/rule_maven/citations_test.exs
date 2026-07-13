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

    test "names the legality trigger for a Yes/No answer the other triggers miss" do
      # The real miss this trigger exists for: asked "can I trade with the bank
      # on another player's turn?", the model answered **Yes** while quoting the
      # very sentence that forbids it. No number, no unquoted trigger word (the
      # answer's "only"/"if" both appear in the quotes), and the answer is
      # SHORTER than its quotes so the length ratio can't fire either — so the
      # grounding critic never ran and a flat contradiction reached the user
      # wearing a valid citation. A polarity flip is the single most damaging
      # error this system can make, and it is exactly the class the cheap
      # heuristics are blind to, so every yes/no legality answer gets checked.
      quotes = [
        "You may trade with another player between your turns, but only if it is that player's turn and they elect to trade with you.",
        "You may not trade with the bank during another player's turn."
      ]

      answer =
        "Yes, a player can trade with the bank during another player's turn, but only if it is that player's turn and they elect to trade with you."

      assert Citations.suspicion(answer, quotes, quotes) == :legality
    end

    test "the legality trigger fires on a bolded No lead too" do
      quotes = ["A settlement must connect to one of your own roads."]
      answer = "**No** — a settlement must connect to one of your own roads."

      assert Citations.suspicion(answer, quotes, quotes) == :legality
    end

    test "a non-legality answer that merely contains the word yes does not trigger" do
      # "yes" has to be the ANSWER's verdict lead, not a word buried in prose,
      # or the trigger degrades into "run the critic on everything".
      quotes = ["Players may answer yes or no to a trade offer."]
      sources = quotes
      answer = "Players may answer yes or no to a trade offer."

      assert Citations.suspicion(answer, quotes, sources) == nil
    end

    test "a stronger trigger still wins over legality" do
      # Ordering matters only for the log label, but a fabricated number is the
      # more specific diagnosis — keep it reported as :numeric.
      sources = ["[Page 3] Each player draws three cards."]
      answer = "Yes — each player draws 5 cards."

      assert Citations.suspicion(answer, [], sources) == :numeric
    end
  end

  # The worst failure this system produced, and the one the LLM critic cannot
  # see: the answer affirms the exact thing its OWN cited quote forbids.
  #
  #   Q: "Can I trade with the bank during another player's turn?"
  #   A: "Yes, a player can trade with the bank during another player's turn."
  #   cited quote: "You may not trade with the bank during another player's turn."
  #
  # Handed both texts, the cheap critic model answered "grounded" 3 times out of
  # 3 — every phrase in the answer does appear in the source, so a
  # support-shaped check passes. Polarity is not a support question, it is a
  # logic question, and it is decidable here without an LLM: the quote forbids a
  # predicate, and the answer asserts that same predicate with no negation in
  # front of it. So this is a deterministic check, not another prompt.
  describe "contradicted_quote/2" do
    test "catches a Yes answer that affirms what its quote forbids" do
      quotes = ["You may not trade with the bank during another player's turn."]
      answer = "Yes, a player can trade with the bank during another player's turn."

      assert Citations.contradicted_quote(answer, quotes) == hd(quotes)
    end

    test "modal verbs are interchangeable (may / can / could)" do
      quotes = ["A player cannot build a settlement adjacent to another settlement."]
      answer = "Yes — a player may build a settlement adjacent to another settlement."

      assert Citations.contradicted_quote(answer, quotes) == hd(quotes)
    end

    test "an answer that RESTATES the prohibition is not a contradiction" do
      # The overwhelmingly common shape: the answer agrees with the quote.
      quotes = ["You may not trade with the bank during another player's turn."]
      answer = "No — you may not trade with the bank during another player's turn."

      assert Citations.contradicted_quote(answer, quotes) == nil
    end

    test "a Yes answer that cites a prohibition as a CAVEAT is not a contradiction" do
      # "Yes, X — but not Y" legitimately quotes the rule forbidding Y. The
      # predicate appears in the answer, but negated. Flagging this would fire
      # the critic on a large class of correct, nuanced answers.
      quotes = ["You may not trade with the bank during another player's turn."]

      answer =
        "Yes — you may trade with another player on their turn, but you may not trade with the bank during another player's turn."

      assert Citations.contradicted_quote(answer, quotes) == nil
    end

    test "an unrelated prohibition is not a contradiction" do
      quotes = ["You may not trade like resources."]
      answer = "Yes, you may build a road along the coast."

      assert Citations.contradicted_quote(answer, quotes) == nil
    end

    test "a quote with no prohibition is never contradicted" do
      quotes = ["Each city is worth 2 victory points."]
      answer = "Yes, each city is worth 2 victory points."

      assert Citations.contradicted_quote(answer, quotes) == nil
    end

    test "only a Yes-leading answer can contradict a prohibition" do
      # An explanatory answer that happens to restate a predicate is not making
      # a legality claim; the Yes lead is what asserts permission.
      quotes = ["You may not trade with the bank during another player's turn."]
      answer = "Trading with the bank during another player's turn is covered on page 14."

      assert Citations.contradicted_quote(answer, quotes) == nil
    end

    test "handles nil and empty input" do
      assert Citations.contradicted_quote(nil, ["You may not pass."]) == nil
      assert Citations.contradicted_quote("Yes, you may pass.", []) == nil
      assert Citations.contradicted_quote("Yes, you may pass.", [nil]) == nil
    end
  end

  describe "quoted_verbatim?/2" do
    @texts [
      "[Page 1]\nPerk cards may be played only during the Hero Phase.",
      "[Page 2]\nPOW symbols are resolved during the Monster Phase."
    ]

    test "a real quote verifies despite punctuation/case drift" do
      assert Citations.quoted_verbatim?(
               "perk cards MAY be played, only during the hero phase",
               @texts
             )
    end

    test "a fabricated quote fails" do
      refute Citations.quoted_verbatim?("The maximum Terror Level is 6", @texts)
    end

    test "a paraphrase fails" do
      refute Citations.quoted_verbatim?("Perk cards are restricted to the Hero Phase", @texts)
    end

    test "a too-short quote cannot verify" do
      # The caller is deciding whether to spend money on this quote's strength;
      # unverifiable means no.
      refute Citations.quoted_verbatim?("Perk", @texts)
    end

    test "non-binary input fails" do
      refute Citations.quoted_verbatim?(nil, @texts)
      refute Citations.quoted_verbatim?(%{}, @texts)
      refute Citations.quoted_verbatim?("Perk cards may be played", "not a list")
    end

    test "a real prefix spliced to a fabricated tail fails" do
      # The old ten-word-needle match let an invented tail ride a real opening;
      # the full quote must appear in the text.
      refute Citations.quoted_verbatim?(
               "Perk cards may be played only during the Hero Phase and also block POW symbols at any time",
               @texts
             )
    end
  end

  describe "distinct_verified_quotes/2" do
    @texts [
      "[Page 1]\nPerk cards may be played only during the Hero Phase.",
      "[Page 2]\nPOW symbols are resolved during the Monster Phase."
    ]

    test "keeps distinct verified quotes in order" do
      assert Citations.distinct_verified_quotes(
               [
                 "Perk cards may be played only during the Hero Phase",
                 "POW symbols are resolved during the Monster Phase"
               ],
               @texts
             ) == [
               "Perk cards may be played only during the Hero Phase",
               "POW symbols are resolved during the Monster Phase"
             ]
    end

    test "an exact duplicate counts once" do
      assert Citations.distinct_verified_quotes(
               [
                 "Perk cards may be played only during the Hero Phase",
                 "Perk cards may be played only during the Hero Phase"
               ],
               @texts
             )
             |> length() == 1
    end

    test "punctuation/case respellings of one rule count once" do
      assert Citations.distinct_verified_quotes(
               [
                 "Perk cards may be played only during the Hero Phase",
                 "perk cards MAY be played, only during the hero phase!"
               ],
               @texts
             )
             |> length() == 1
    end

    test "fabricated and non-string entries are dropped" do
      assert Citations.distinct_verified_quotes(
               [
                 "The maximum Terror Level is 6",
                 nil,
                 42,
                 "POW symbols are resolved during the Monster Phase"
               ],
               @texts
             ) == ["POW symbols are resolved during the Monster Phase"]
    end

    test "non-list inputs yield no quotes" do
      assert Citations.distinct_verified_quotes("not a list", @texts) == []
      assert Citations.distinct_verified_quotes(["Perk cards may be played"], nil) == []
    end
  end

  describe "ignored_numbers/2" do
    test "flags the exact setup-default failure" do
      # Question states Terror 0; answer derives the generic 3 - 1 = 2 case.
      assert Citations.ignored_numbers(
               "What is the Terror Level in a solo game after defeating one Monster when the Terror Level is 0?",
               "In a solo game the Terror Level starts at 3. Defeating a Monster moves it down one space, so it would be 2."
             ) == ["0"]
    end

    test "an answer that engages every stated number passes" do
      assert Citations.ignored_numbers(
               "What do two players each with one settlement receive when the bank has 1 brick left?",
               "With only 1 brick left and two players due brick, no player receives any."
             ) == []
    end

    test "spelled-out numbers count as mentions" do
      assert Citations.ignored_numbers(
               "How many cards are discarded with 9 cards in hand when a 7 is rolled?",
               "You discard half, rounded down — with nine cards that is four; the seven triggers the discard."
             ) == []
    end

    test "a ratio is satisfied by the exact ratio or both components" do
      q = "How many trades with a 2:1 brick harbor and 9 brick in hand?"

      assert Citations.ignored_numbers(q, "The 2:1 harbor allows 4 trades with 9 brick.") == []

      assert Citations.ignored_numbers(
               q,
               "Trading 2 brick for 1 resource each time, 9 brick allows 4 trades."
             ) == []

      assert Citations.ignored_numbers(
               q,
               "The brick harbor gives a better rate; 9 brick allows several trades."
             ) ==
               ["2:1"]
    end

    test "questions with no numbers never flag" do
      assert Citations.ignored_numbers(
               "Can a Perk card block a POW symbol?",
               "No — Perk cards are Hero Phase only."
             ) == []
    end

    test "non-binary input never flags" do
      assert Citations.ignored_numbers(nil, "an answer") == []
      assert Citations.ignored_numbers("a question with 3", nil) == []
    end
  end
end
