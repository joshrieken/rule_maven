defmodule RuleMaven.LLM.QuestionFacetsTest do
  @moduledoc """
  Guards the pool against serving one question's answer to a DIFFERENT question.

  Every rejection case here is a pair that actually landed a false DIRECT pool hit
  against real pooled rows — no LLM call, no critic, nothing else looking. The
  acceptance cases are the other half of the job: this guard sits in front of the
  only free answer in the system, so over-blocking quietly bills every paraphrase
  at full price.
  """
  use ExUnit.Case, async: true

  alias RuleMaven.LLM.QuestionFacets, as: Facets

  describe "rejects the flips that were actually served" do
    test "before/after — the worst one" do
      # Live: served "**No.** Trading before rolling is not permitted." to this.
      # Trading after rolling is what a player does every turn.
      refute Facets.compatible?(
               "Can a player trade after rolling?",
               "Can a player trade before rolling?"
             )

      assert Facets.conflict(
               "Can a player trade after rolling?",
               "Can a player trade before rolling?"
             ) == :temporal

      refute Facets.compatible?(
               "Is the robber moved before discarding on a 7?",
               "Is the robber moved after discarding on a 7?"
             )
    end

    test "may/must — permission served for an obligation" do
      # Live: "Must I move the robber?" -> "Yes, the robber CAN be moved."
      refute Facets.compatible?(
               "Must I move the robber when I play a knight?",
               "Can the robber be moved when a Knight card is played?"
             )

      assert Facets.conflict(
               "Must I move the robber when I play a knight?",
               "Can the robber be moved when a Knight card is played?"
             ) == :modal
    end

    test "more/fewer" do
      refute Facets.compatible?(
               "Do I discard when I have fewer than seven cards?",
               "Do I discard when I have more than seven cards?"
             )

      assert Facets.conflict(
               "Do I discard when I have fewer than seven cards?",
               "Do I discard when I have more than seven cards?"
             ) == :comparative
    end

    test "block/allow" do
      refute Facets.compatible?(
               "Does the robber allow resource production on the hex it occupies?",
               "Does the robber block resource production on an empty hex?"
             )
    end

    test "numbers — the rule IS the number" do
      refute Facets.compatible?(
               "How many cards must be discarded on an 8?",
               "How many cards must be discarded on a 7?"
             )

      assert Facets.conflict(
               "How many cards must be discarded on an 8?",
               "How many cards must be discarded on a 7?"
             ) == :number

      refute Facets.compatible?(
               "Do I discard if I have more than 9 cards?",
               "Do I discard if I have more than 7 cards?"
             )

      # A DIFFERENT ratio falls out of the digit scan: {4,1} vs {2,1}.
      refute Facets.compatible?(
               "Can I trade with the bank at 2:1?",
               "Can I trade with the bank at 4:1?"
             )

      # A REVERSED ratio has the same digits, so the set check passes it — the
      # colon-ratio order check is what catches 2:1 (give 2 get 1) vs 1:2.
      refute Facets.compatible?(
               "Can I trade with the bank at 2:1?",
               "Can I trade with the bank at 1:2?"
             )

      assert Facets.conflict(
               "Can I trade with the bank at 2:1?",
               "Can I trade with the bank at 1:2?"
             ) == :ratio

      # Same ratio, reworded around it, still matches.
      assert Facets.compatible?(
               "Is the harbor rate 3:1?",
               "Can I trade at 3:1 with a generic harbor?"
             )

      # A rewrite may drop a ratio premise but never reverse it.
      refute Facets.preserved_in_rewrite?(
               "At a 2:1 harbor can I trade?",
               "Can I trade at a 1:2 harbor?"
             )

      refute Facets.compatible?("Can a player roll only two dice?", "Can a player roll only one die?")
    end

    test "number-unit swap — same digits, opposite roles, 0.99" do
      # {7,8} on both sides, so the digit SET passes. The unit binding is what
      # separates them: 8-cards (discard) vs 7-cards (do not).
      refute Facets.compatible?(
               "Do I discard on a 7 with 8 cards?",
               "Do I discard on an 8 with 7 cards?"
             )

      assert Facets.conflict(
               "Do I discard on a 7 with 8 cards?",
               "Do I discard on an 8 with 7 cards?"
             ) == :number

      # The legitimate reorder must STILL match: only "8 cards" binds a unit on
      # each side (the 7 is followed by "with"/nothing), so both carry {8,card}.
      assert Facets.compatible?(
               "Do I discard when I roll a 7 with 8 cards?",
               "With 8 cards, do I discard when I roll a 7?"
             )

      # Singular/plural of the same unit-number is not a disagreement.
      assert Facets.compatible?(
               "Do I keep 1 card?",
               "Do I keep 1 cards?"
             )

      # A rewrite may DROP a unit-number premise but never swap its unit.
      assert Facets.preserved_in_rewrite?(
               "If I roll a 7 with 8 cards, how many do I discard?",
               "How many cards are discarded on a 7?"
             )

      refute Facets.preserved_in_rewrite?(
               "How many do I discard with 8 cards?",
               "How many do I discard with 7 cards?"
             )
    end

    test "same/different — a single-token antonym that stays 0.97 on the embedding" do
      # Live: "Can the robber be placed on the same hex?" is a real pooled row,
      # so "...a different hex?" false-hit it and served the opposite.
      refute Facets.compatible?(
               "Can the robber be placed on a different hex?",
               "Can the robber be placed on the same hex?"
             )

      assert Facets.conflict(
               "Can the robber be placed on a different hex?",
               "Can the robber be placed on the same hex?"
             ) == :identity

      # "another" and "different" are BOTH the different-pole, so a real
      # paraphrase off the pooled "another settlement" survives.
      assert Facets.compatible?(
               "two spaces from another settlement",
               "two spaces from a different settlement"
             )
    end

    test "gain/lose — the value direction inverts the answer" do
      refute Facets.compatible?(
               "Do I gain a victory point for the longest road?",
               "Do I lose a victory point for the longest road?"
             )

      assert Facets.conflict(
               "Do I win if I reach ten points?",
               "Do I lose if I reach ten points?"
             ) == :value_direction
    end

    test "include/exclude — whether a rule counts or ignores something" do
      refute Facets.compatible?(
               "Does the longest road include roads broken by a settlement?",
               "Does the longest road exclude roads broken by a settlement?"
             )

      refute Facets.compatible?(
               "Does the longest road count broken segments?",
               "Does the longest road ignore broken segments?"
             )
    end

    test "open/closed — a narrow state pair, observed at 0.94" do
      refute Facets.compatible?(
               "Is trading open before I roll?",
               "Is trading closed before I roll?"
             )
    end

    test "clockwise/counterclockwise — direction of play, 0.95" do
      refute Facets.compatible?(
               "Does play proceed clockwise?",
               "Does play proceed counterclockwise?"
             )

      assert Facets.conflict(
               "Does play proceed clockwise?",
               "Does play proceed counterclockwise?"
             ) == :direction
    end

    test "first/last — turn order inverts the answer, 0.93" do
      refute Facets.compatible?(
               "Does the first player take the opening turn?",
               "Does the last player take the opening turn?"
             )

      assert Facets.conflict(
               "Does the first player take the opening turn?",
               "Does the last player take the opening turn?"
             ) == :order
    end

    test "steal/give — the robber transfer direction, 0.93" do
      refute Facets.compatible?(
               "Does the robber let me steal a card?",
               "Does the robber let me give a card?"
             )

      assert Facets.conflict(
               "Does the robber let me steal a card?",
               "Does the robber let me give a card?"
             ) == :transfer
    end

    test "face up/down — hidden vs public information, 0.99" do
      # The single scariest pair found: the whole meaning of a card game's
      # hidden information hangs on it, and the embedding barely moves.
      refute Facets.compatible?(
               "Are development cards kept face up?",
               "Are development cards kept face down?"
             )

      assert Facets.conflict(
               "Are development cards kept face up?",
               "Are development cards kept face down?"
             ) == :visibility

      # "hidden"/"face down" are the SAME pole, so a paraphrase survives.
      assert Facets.compatible?(
               "Are development cards kept face down?",
               "Are development cards kept hidden?"
             )
    end

    test "bare up/down is NOT gated — only the face-up/face-down phrase" do
      # "up to seven" must not collide with anything on the visibility axis;
      # gating the bare token would wreck every question that counts cards.
      assert Facets.compatible?(
               "Do I discard with up to seven cards?",
               "Do I discard with up to seven cards in hand?"
             )
    end

    test "empty/occupied — whether a space holds a piece, 0.93" do
      refute Facets.compatible?(
               "Can the robber sit on an empty hex?",
               "Can the robber sit on an occupied hex?"
             )

      assert Facets.conflict(
               "Can the robber sit on an empty hex?",
               "Can the robber sit on an occupied hex?"
             ) == :occupancy

      # "vacant"/"unoccupied" are the SAME pole as "empty", so a paraphrase survives.
      assert Facets.compatible?(
               "Can the robber sit on an empty hex?",
               "Can the robber sit on a vacant hex?"
             )
    end

    test "highest/lowest — a superlative that decides a roll-off, 0.92" do
      refute Facets.compatible?(
               "Does the player with the highest roll go first?",
               "Does the player with the lowest roll go first?"
             )

      assert Facets.conflict(
               "Does the player with the highest roll go first?",
               "Does the player with the lowest roll go first?"
             ) == :superlative

      # "greatest" sits on the HIGHEST pole, so a paraphrase survives.
      assert Facets.compatible?(
               "Does the player with the highest roll go first?",
               "Does the player with the greatest roll go first?"
             )
    end

    test "inclusive vs exclusive bound on the same number, 0.97" do
      # ">= 7" vs "> 7" share the number 7 and both put their comparative word on
      # the SAME side, so no existing guard sees a difference — but the answer
      # flips at exactly 7, and that is the discard-on-a-7 rule.
      refute Facets.compatible?(
               "Do I discard with at least seven cards?",
               "Do I discard with more than seven cards?"
             )

      assert Facets.conflict(
               "Do I discard with at least seven cards?",
               "Do I discard with more than seven cards?"
             ) == :bound

      # "<= 7" vs "< 7" is the same flip on the upper bound.
      refute Facets.compatible?(
               "Is it safe with at most seven cards?",
               "Is it safe with fewer than seven cards?"
             )

      # "up to 3" (<=3) vs "at least 3" (>=3) are opposite bound directions.
      refute Facets.compatible?(
               "Do I draw up to three cards?",
               "Do I draw at least three cards?"
             )
    end

    test "same-inclusivity bound paraphrases still match" do
      # "> 7" phrased two ways stays compatible; the guard fires on inclusivity,
      # not on the surface phrase.
      assert Facets.compatible?(
               "Do I discard with more than seven cards?",
               "Do I discard with over seven cards?"
             )

      assert Facets.compatible?(
               "Do I discard with at least seven cards?",
               "Do I discard with seven or more cards?"
             )

      # A bound marker with no adjacent number is not a bound: "game over at ten"
      # must not collide with a real threshold.
      assert Facets.compatible?(
               "Is the game over at ten points?",
               "Does the game end at ten points?"
             )
    end

    test "top/bottom — deck-position manipulation, hidden-info class, 0.96" do
      refute Facets.compatible?(
               "Do I draw from the top of the deck?",
               "Do I draw from the bottom of the deck?"
             )

      assert Facets.conflict(
               "Do I draw from the top of the deck?",
               "Do I draw from the bottom of the deck?"
             ) == :deck_position

      # A question naming neither pole survives — only top-vs-bottom opposition
      # fires, so "draw a card from the deck" still matches, and "on top of a
      # resource" does not fire without a `bottom` on the other side.
      assert Facets.compatible?(
               "Do I draw from the top of the deck?",
               "Do I draw a card from the deck?"
             )

      assert Facets.compatible?(
               "Can the robber sit on top of a resource?",
               "Can the robber block a resource?"
             )
    end

    test "ascending/descending — sort direction, 0.98" do
      refute Facets.compatible?(
               "Are the cards sorted in ascending order?",
               "Are the cards sorted in descending order?"
             )

      assert Facets.conflict(
               "Are the cards sorted in ascending order?",
               "Are the cards sorted in descending order?"
             ) == :sort_order

      # Naming neither pole survives — the generic "how are they sorted" still matches.
      assert Facets.compatible?(
               "Are the cards sorted in ascending order?",
               "How are the cards sorted?"
             )
    end

    test "increase/decrease — magnitude change, 0.94, reduce is on the decrease side" do
      refute Facets.compatible?(
               "Does the effect increase my hand size?",
               "Does the effect decrease my hand size?"
             )

      assert Facets.conflict(
               "Does the effect increase my hand size?",
               "Does the effect reduce my hand size?"
             ) == :magnitude

      # `reduce` is a synonym of `decrease`, not an opposition to it.
      assert Facets.compatible?(
               "Does the effect decrease my hand size?",
               "Does the effect reduce my hand size?"
             )

      # A neutral "change" names neither pole and still matches.
      assert Facets.compatible?(
               "Does the effect increase my hand size?",
               "Does the effect change my hand size?"
             )
    end

    test "forward/backward — movement direction, 0.95" do
      refute Facets.compatible?(
               "Does the token move forward on the track?",
               "Does the token move backward on the track?"
             )

      assert Facets.conflict(
               "Does the token move forward on the track?",
               "Does the token move backward on the track?"
             ) == :movement

      assert Facets.compatible?(
               "Does the token move forward on the track?",
               "Does the token move on the track?"
             )
    end

    test "horizontal/vertical — placement orientation, 0.94; up is not an axis" do
      refute Facets.compatible?(
               "Must the tiles be placed horizontally?",
               "Must the tiles be placed vertically?"
             )

      assert Facets.conflict(
               "Must the tiles be placed horizontally?",
               "Must the tiles be placed vertically?"
             ) == :orientation

      assert Facets.compatible?(
               "Must the tiles be placed horizontally?",
               "How must the tiles be placed?"
             )

      # `up` must not become an orientation pole — it belongs to the `up to N`
      # bound and everyday phrasing.
      assert Facets.compatible?(
               "Can I hold up to seven cards?",
               "May I keep up to seven cards?"
             )
    end

    test "inner/outer — radial position, 0.96" do
      refute Facets.compatible?(
               "Do I place the marker on the inner ring?",
               "Do I place the marker on the outer ring?"
             )

      assert Facets.conflict(
               "Do I place the marker on the inner ring?",
               "Do I place the marker on the outer ring?"
             ) == :radial

      assert Facets.compatible?(
               "Do I place the marker on the inner ring?",
               "Do I place the marker on a ring?"
             )
    end

    test "major/minor — scoring tier, 0.93" do
      refute Facets.compatible?(
               "Is this scored as a major set?",
               "Is this scored as a minor set?"
             )

      assert Facets.conflict(
               "Is this scored as a major set?",
               "Is this scored as a minor set?"
             ) == :tier
    end

    test "compass directions are mutually exclusive, not two-sided" do
      refute Facets.compatible?("Does the piece move north?", "Does the piece move south?")
      refute Facets.compatible?("Does the piece move east?", "Does the piece move west?")

      # The whole point of the set treatment: north also flips against east, which
      # no opposite-pair axis can express.
      refute Facets.compatible?("Does the piece move north?", "Does the piece move east?")

      assert Facets.conflict("Does the piece move north?", "Does the piece move east?") ==
               :compass

      # Naming no direction still matches.
      assert Facets.compatible?("Does the piece move north?", "Does the piece move?")
    end

    test "upper/lower — vertical board position, 0.95" do
      refute Facets.compatible?(
               "Is the token on the upper track?",
               "Is the token on the lower track?"
             )

      assert Facets.conflict(
               "Is the token on the upper track?",
               "Is the token on the lower track?"
             ) == :vertical_position
    end

    test "leftmost/rightmost — the -most forms are unambiguous, so gated, 0.95" do
      refute Facets.compatible?("Do I take the leftmost card?", "Do I take the rightmost card?")

      assert Facets.conflict("Do I take the leftmost card?", "Do I take the rightmost card?") ==
               :horizontal_extreme

      # Bare left/right stays UNGATED — "right" is polysemous.
      assert Facets.compatible?(
               "Does play pass to the left?",
               "Is it right to pass play along?"
             )
    end

    test "ordinals name a position and the number guard misses them" do
      # Word ordinals.
      refute Facets.compatible?("Do I move to the fourth space?", "Do I move to the fifth space?")

      assert Facets.conflict("Do I move to the fourth space?", "Do I move to the fifth space?") ==
               :ordinal

      # Digit-suffix ordinals — "2nd" is not a cardinal number.
      refute Facets.compatible?("Does the 1st player act?", "Does the 2nd player act?")

      # Word and digit forms of the SAME ordinal fold together.
      assert Facets.compatible?("Does the first player act?", "Does the 1st player act?")

      # first/last is still the order axis, not the ordinal set.
      assert Facets.conflict("Does the first player act?", "Does the last player act?") == :order
    end

    test "frequency (how many times) is its own count, separate from quantity" do
      refute Facets.compatible?("Can I attack twice this turn?", "Can I attack three times this turn?")

      assert Facets.conflict("Can I attack twice this turn?", "Can I attack three times this turn?") ==
               :frequency

      refute Facets.compatible?("Do I roll twice?", "Do I roll thrice?")

      # A frequency must NOT be equated with a quantity: "attack twice" (two
      # attacks) is not "attack two targets" (one attack, two targets).
      assert Facets.compatible?("Do I attack twice?", "Do I attack two targets?")

      # `once` is left ungated — it doubles as "when" ("once you build, ...").
      assert Facets.compatible?("Do I draw once?", "Do I draw twice?")
    end

    test "exactly N is an equality bound, flipping against at-least / more-than / up-to" do
      refute Facets.compatible?(
               "Do I need exactly seven cards to win?",
               "Do I need at least seven cards to win?"
             )

      refute Facets.compatible?(
               "Do I need exactly seven cards to win?",
               "Do I need more than seven cards to win?"
             )

      refute Facets.compatible?("Can I hold exactly five cards?", "Can I hold up to five cards?")

      assert Facets.conflict(
               "Do I need exactly seven cards to win?",
               "Do I need at least seven cards to win?"
             ) == :bound

      # Emphasis over a plain count is the SAME requirement, and the filler sense
      # (no adjacent number) must not trip the bound.
      assert Facets.compatible?("Must I have precisely three coins?", "Must I have three coins?")

      assert Facets.compatible?(
               "Tell me exactly what happens on a seven.",
               "Tell me what happens on a seven."
             )
    end

    test "borrow/lend — direction of a loan, 0.94" do
      refute Facets.compatible?("Can I borrow a card?", "Can I lend a card?")
      assert Facets.conflict("Can I borrow a card?", "Can I lend a card?") == :lending
      assert Facets.compatible?("Can I borrow a card?", "Can I use a card?")
    end

    test "instead-of vs in-addition-to — replacement vs augmentation, 0.93" do
      refute Facets.compatible?(
               "Do I resolve this effect instead of drawing?",
               "Do I resolve this effect in addition to drawing?"
             )

      assert Facets.conflict(
               "Do I resolve this effect instead of drawing?",
               "Do I resolve this effect in addition to drawing?"
             ) == :replacement
    end

    test "a reversed prose trade ratio no longer matches its opposite" do
      # The colon form was already gated; the prose form ("2 wood for 1 ore") was
      # not, because the resource nouns were off the unit whitelist. Binding each
      # number to its own resource catches the reversal order-independently.
      refute Facets.compatible?(
               "Do I trade two wood for one ore?",
               "Do I trade one wood for two ore?"
             )

      refute Facets.compatible?("Trade 2 wood for 1 ore?", "Trade 1 wood for 2 ore?")

      # A genuine paraphrase, and a resource synonym, must still match.
      assert Facets.compatible?(
               "Do I trade two wood for one ore?",
               "Do I exchange two wood for one ore?"
             )

      assert Facets.compatible?("Do I collect two wood?", "Do I collect two lumber?")
    end

    test "most/least stay on the comparative axis, not the superlative one" do
      # `most`/`least` are the at-most/at-least BOUND ("at least seven" = seven or
      # more), a different sense than the highest/lowest superlative. They must not
      # leak onto the superlative axis, or a token would fire two axes at once.
      assert Facets.conflict(
               "Do I discard with at least seven cards?",
               "Do I discard with at most seven cards?"
             ) == :comparative
    end

    test "valid/invalid is gated as a negation (delegated to Polarity)" do
      # "invalid" carries negation exactly like "illegal", so it rides Polarity
      # rather than an axis here.
      refute Facets.compatible?(
               "Is a trade with the bank valid before rolling?",
               "Is a trade with the bank invalid before rolling?"
             )

      assert Facets.conflict(
               "Is a trade with the bank valid before rolling?",
               "Is a trade with the bank invalid before rolling?"
             ) == :negation
    end

    test "negation is still gated (delegated to Polarity)" do
      refute Facets.compatible?(
               "Can the robber NOT be placed on the desert hex?",
               "Can the robber be placed on the desert hex?"
             )

      assert Facets.conflict(
               "Is it forbidden to trade before rolling?",
               "Can a player trade before rolling?"
             ) == :negation
    end
  end

  describe "preserved_in_rewrite?/2 — the normalizer must not snap a question onto its neighbour" do
    test "rejects a rewrite that crosses an answer-deciding axis" do
      # The nearest canonical question to this one IS its opposite, and the
      # normalizer is handed the nearest canonicals as hints.
      refute Facets.preserved_in_rewrite?(
               "Can a player trade after rolling?",
               "Can a player trade before rolling?"
             )

      refute Facets.preserved_in_rewrite?(
               "Must I move the robber?",
               "Can the robber be moved?"
             )

      refute Facets.preserved_in_rewrite?(
               "Is it forbidden to trade before rolling?",
               "Can a player trade before rolling?"
             )
    end

    test "a number may be DROPPED as a premise but never introduced or swapped" do
      # Legitimate: the 8 is a premise, and canonicalizing drops it.
      assert Facets.preserved_in_rewrite?(
               "If I roll a 7 and I have 8 cards, how many do I discard?",
               "How many cards must be discarded on a 7?"
             )

      # Not legitimate: this invents the very fact in dispute.
      refute Facets.preserved_in_rewrite?(
               "How many cards must be discarded on an 8?",
               "How many cards must be discarded on a 7?"
             )

      refute Facets.preserved_in_rewrite?(
               "How many cards do I discard?",
               "How many cards must be discarded on a 7?"
             )
    end

    test "an ordinary tidy-up survives" do
      assert Facets.preserved_in_rewrite?(
               "can i stick the robber on the desert lol",
               "Can the robber be placed on the desert hex?"
             )

      assert Facets.preserved_in_rewrite?(
               "how many cards do i toss when someone rolls a 7?",
               "How many cards must be discarded on a 7?"
             )
    end
  end

  describe "still lets real paraphrases through — the pool must keep working" do
    test "a reworded question with the same facets matches" do
      assert Facets.compatible?(
               "how many cards do i toss when someone rolls a 7?",
               "How many cards must be discarded on a 7?"
             )

      assert Facets.compatible?(
               "is trading allowed before you roll?",
               "Can a player trade before rolling?"
             )

      assert Facets.compatible?(
               "can i stick the robber on the desert?",
               "Can the robber be placed on the desert hex?"
             )
    end

    test "spelled and written numbers are the same number" do
      assert Facets.compatible?(
               "Do I discard with more than seven cards?",
               "Do I discard with more than 7 cards?"
             )
    end

    test "an axis only decides when BOTH sides name it" do
      # "must" vs silence is not a disagreement — the second question simply does
      # not raise obligation. Blocking here would cost a hit and learn nothing.
      assert Facets.compatible?(
               "How many cards must be discarded on a 7?",
               "How many cards do I discard on a 7?"
             )

      # Same for numbers: a question that mentions none is not disputing them.
      assert Facets.compatible?(
               "What are the rules for the robber?",
               "What are the robber rules?"
             )
    end

    test "same side of an axis, different word, still matches" do
      assert Facets.compatible?(
               "Is a player permitted to trade prior to rolling?",
               "Can a player trade before rolling?"
             )
    end

    test "person-paraphrase is deliberately NOT gated" do
      # "do I" / "do you" / "does a player" are the most common paraphrase of
      # one another. Gating a pronoun axis would bill every rephrase; the rare
      # possessor flip ("my hex" vs "their hex") is not worth that cost.
      assert Facets.compatible?(
               "Do I collect resources on this roll?",
               "Does a player collect resources on this roll?"
             )

      assert Facets.compatible?(
               "Can I move the robber?",
               "Can you move the robber?"
             )
    end

    test "each/any and per-turn/per-game are deliberately NOT gated" do
      # "each"/"any"/"every" and "turn"/"game" are too common and too often
      # interchangeable in casual phrasing to gate an answer on.
      assert Facets.compatible?(
               "Does each player discard on a seven?",
               "Does any player discard on a seven?"
             )

      assert Facets.compatible?(
               "Can I play one knight per turn?",
               "Can I play one knight per game?"
             )
    end

    test "the new antonym axes only fire when BOTH sides name a pole" do
      # "win" on one side, neither win nor lose on the other — not a dispute.
      assert Facets.compatible?(
               "Do I win at ten victory points?",
               "How do I reach ten victory points?"
             )

      # "same" with no different-pole word opposite it.
      assert Facets.compatible?(
               "Can the robber stay on the same hex?",
               "Can the robber remain where it is?"
             )

      # "count/include" with no exclude-pole opposite it.
      assert Facets.compatible?(
               "Does the longest road count broken segments?",
               "How is the longest road measured?"
             )
    end

    test "left/right is deliberately NOT gated — 'left' also means remaining" do
      # "left" doubles as REMAINING; gating a left/right direction axis would wreck
      # every "how many cards are left" question. Documented ungated at 0.96.
      assert Facets.compatible?(
               "How many cards are left in the deck?",
               "How many cards are left in my hand?"
             )

      assert Facets.compatible?(
               "Do cards pass to the player on my left?",
               "Do cards pass to the player on my right?"
             )
    end

    test "bare once is NOT gated — 'once' also means when" do
      # "once you roll a seven, discard" uses once=WHEN, not once=one time, so the
      # bare token cannot be mapped to a count without false-gating a timing
      # paraphrase. Only the pinned frequency shapes count — see the next test.
      assert Facets.compatible?(
               "Once you roll a seven, do you discard?",
               "When you roll a seven, do you discard?"
             )

      # "once a player" is the conjunction again, even though "once a" opens it.
      assert Facets.compatible?(
               "Once a player builds a settlement, do they draw?",
               "Does a player draw after building a settlement?"
             )
    end

    test "'once per X' and 'once a turn' ARE frequencies — vs twice, 0.956" do
      refute Facets.compatible?(
               "Can I play a knight once per turn?",
               "Can I play a knight twice per turn?"
             )

      assert Facets.conflict(
               "Can I play a knight once per turn?",
               "Can I play a knight twice per turn?"
             ) == :frequency

      refute Facets.compatible?(
               "Can I play a knight once a turn?",
               "Can I play a knight twice per turn?"
             )

      # Same frequency, different phrasing — still a match.
      assert Facets.compatible?(
               "Can I play a knight once per turn?",
               "Is playing a knight limited to once a turn?"
             )
    end

    test "hyphen and space spellings collapse onto the same pole" do
      # "counter-clockwise" split naively into counter+CLOCKWISE — the guard read
      # it as the OPPOSITE pole and confirmed the flipped candidate at 0.94.
      refute Facets.compatible?(
               "Does play proceed counter-clockwise?",
               "Does play proceed clockwise?"
             )

      assert Facets.conflict(
               "Does play proceed counter clockwise?",
               "Does play proceed clockwise?"
             ) == :direction

      # Same pole across spellings — a paraphrase survives.
      assert Facets.compatible?(
               "Does play proceed counter-clockwise?",
               "Does play move counterclockwise?"
             )

      # "face-up" hyphenated slipped past the visibility axis at 0.96.
      refute Facets.compatible?(
               "Are development cards kept face-up?",
               "Are development cards kept face down?"
             )
    end

    test "'have to' is obligation — vs can, measured 0.92, exactly at the floor" do
      refute Facets.compatible?(
               "Do I have to play a development card the turn I buy it?",
               "Can I play a development card the turn I buy it?"
             )

      assert Facets.conflict(
               "Do I have to move the robber?",
               "Can the robber be moved?"
             ) == :modal

      # Same side as must — the normalizer's usual rewrite survives.
      assert Facets.compatible?(
               "Do I have to move the robber?",
               "Must the robber be moved?"
             )

      assert Facets.preserved_in_rewrite?(
               "do I have to move the robber?",
               "Must a player move the robber?"
             )

      refute Facets.preserved_in_rewrite?(
               "do I have to move the robber?",
               "Can a player move the robber?"
             )
    end

    test "bare '2 for 1' trade ratio is ORDERED — same digits, opposite trade, 0.962" do
      # No resource noun beside either number, so the unit-binding path never
      # fires, and the number SETs are equal — only the pair order differs.
      refute Facets.compatible?(
               "Can I trade 2 for 1 at a harbor?",
               "Can I trade 1 for 2 at a harbor?"
             )

      assert Facets.conflict(
               "Can I trade 2 for 1 at a harbor?",
               "Can I trade 1 for 2 at a harbor?"
             ) == :trade_pair

      # Same ordered pair in a different sentence — still a match.
      assert Facets.compatible?(
               "Can I trade 2 for 1 at a harbor?",
               "Is 2 for 1 harbor trading allowed?"
             )

      # Spelled numbers bind the same way.
      refute Facets.compatible?(
               "Can I trade two for one at a harbor?",
               "Can I trade one for two at a harbor?"
             )

      # A rewrite may drop the ratio (premise trimming) but must not reverse it.
      assert Facets.preserved_in_rewrite?(
               "Can I trade 2 for 1 at a harbor?",
               "Can a player trade 2 for 1 at a harbor?"
             )

      refute Facets.preserved_in_rewrite?(
               "Can I trade 2 for 1 at a harbor?",
               "Can a player trade 1 for 2 at a harbor?"
             )
    end
  end
end
