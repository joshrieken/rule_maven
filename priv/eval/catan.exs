# Evaluation probe set for Catan.
#
# These are not invented: every probe here is a question that broke the ask
# pipeline at some point, plus the boundary cases whose fixes must stay fixed.
# The point of the set is to make a model or prompt change MEASURABLE — a cost
# optimization that quietly costs accuracy is a regression, and without a fixed
# set of known answers there is nothing to notice it with.
#
# `must` — a regex the answer must match.
# `must_not` — a regex the answer must NOT match.
# `refuse` — true when the rulebook genuinely does not cover this, and the only
#            correct behavior is to refuse. Serving a confident answer here is
#            the worst failure the system can produce, so it is graded too.
#
# Keep every probe answerable from the Catan base rulebook alone.
[
  %{
    id: "discard_on_7",
    q: "A 7 is rolled and I have 9 cards. How many do I discard?",
    must: ~r/\b4\b/,
    why: "Half of 9 rounded down. The number must actually appear."
  },
  %{
    id: "discard_threshold",
    q: "I have exactly 7 cards when a 7 is rolled. Do I discard?",
    must: ~r/\b(no|not)\b/i,
    must_not: ~r/you must discard/i,
    why: "Boundary: discarding starts ABOVE 7. An off-by-one here is a rules error."
  },
  %{
    id: "longest_road_points",
    q: "How many victory points is Longest Road worth?",
    must: ~r/\b2\b/,
    why: "Straight lookup."
  },
  %{
    id: "false_premise_roads",
    q: "You need 20 road segments for Longest Road, right?",
    must: ~r/\b5\b/,
    must_not: ~r/\b20\b.{0,40}(correct|right|yes)/i,
    why: "FALSE PREMISE. The rulebook says 5. It must correct the 20, not refuse and not agree."
  },
  %{
    id: "false_premise_steal",
    q: "When I play the robber I steal fifteen cards, right?",
    must: ~r/\b(1|one)\b/,
    why: "FALSE PREMISE with a SPELLED number above twelve — the case @number_words used to be blind to."
  },
  %{
    id: "bank_trade_ratio",
    q: "Can I always trade with the bank at 4:1?",
    must: ~r/4:1|4 to 1|four/i,
    why: "True premise. Must be confirmed, NOT 'corrected' into something else."
  },
  %{
    id: "settlement_supply",
    q: "What happens if I have already built all my settlements?",
    must: ~r/\b5\b/,
    why: "Supply limit is 5. Tests that a limit stated in a component list is retrievable."
  },
  %{
    id: "road_connection",
    q: "Can I build a road that only touches an opponent's settlement?",
    # Broad on PHRASING, strict on SUBSTANCE. The first version of this demanded
    # the literal "must connect" and failed a correct answer that said "must
    # always connect" — a probe that grades wording rather than the rule will
    # eventually veto a good model for writing a sentence differently.
    must: ~r/\b(no|cannot|can't|not)\b|must\b.{0,20}\bconnect|your (own|existing)/i,
    why: "Legality question — the class of question the critic exists for."
  },
  %{
    id: "robber_desert",
    q: "Where does the robber start?",
    must: ~r/desert/i,
    why: "Straight lookup, guards against retrieval regressions."
  },
  %{
    id: "uncovered_cat",
    q: "What happens if my cat knocks the robber off the board?",
    refuse: true,
    why: "GENUINELY UNCOVERED. Must refuse. A cheaper model that starts inventing answers here fails the whole point of the product."
  },
  %{
    id: "uncovered_house_rule",
    q: "In our group we always let people trade on other players' turns — is that the official rule?",
    must: ~r/\b(no|only|your (own )?turn)\b/i,
    why: "The rulebook DOES cover trading timing; must not be mistaken for an uncovered house rule."
  },

  # BAIT. These are shaped like rules questions and sound answerable, but the
  # Catan rulebook states no such quantity. They exist to catch a cheap
  # classifier that says "yes, combinable" on anything plausible — a false
  # positive there doesn't just cost accuracy, it BUYS an escalate call to the
  # expensive model, so a cheaper classifier can end up costing more. This is a
  # regression that already happened once (see combinable_question?/4).
  # Graded on FABRICATION, not on refusal. Denying the premise outright ("there
  # is no maximum hand size") is a better answer than a refusal, and an earlier
  # version of these probes wrongly scored exactly that as a failure. What must
  # never happen is a number appearing out of nowhere.
  %{
    id: "bait_max_hand_size",
    q: "What is the maximum hand size in Catan?",
    refuse_ok: true,
    must_not: ~r/(maximum|max|limit)[^.]{0,24}\b(?!7\b)\d+\s*(cards?|resources?)/i,
    why: "BAIT: no hand limit exists outside the 7-roll discard. An invented cap is a fabrication."
  },
  %{
    id: "bait_turn_timer",
    q: "How many seconds does a player get to take their turn?",
    refuse_ok: true,
    must_not: ~r/\b\d+\s*(seconds|minutes)\b/i,
    why: "BAIT: no turn timer exists. Plausible-sounding, entirely absent from the rulebook."
  },
  %{
    id: "bait_max_cities",
    q: "Is there a maximum number of cities I can have on the board at once?",
    must: ~r/\b4\b|\bfour\b/i,
    why: "ANTI-BAIT: this one IS covered (4 cities in the supply). Refusing it is the opposite failure — a set of pure bait would reward a model that refuses everything."
  }
]
