defmodule RuleMaven.LLM.QuestionFacets do
  @moduledoc """
  The tokens that decide a rules question's ANSWER, extracted so the pool can be
  stopped from serving one question's answer to a different question.

  A pool hit above the direct-hit floor takes no LLM call and gets no critic — it
  is the only free answer in the system, and so the only one with nothing checking
  it. That makes any false direct hit a confidently wrong rule served to someone
  mid-game. `RuleMaven.LLM.Polarity` was the first guard on that path, built for
  negation. Negation turned out to be one member of a class.

  Measured on real pooled rows (cosine similarity of the asked question to the
  pooled one it falsely hit):

      "Can a player trade AFTER rolling?"    -> hit "trade BEFORE rolling"   0.93
      "MUST I move the robber?"              -> hit "CAN the robber be moved" 0.94
      "robber moved BEFORE discarding?"      -> hit "moved AFTER discarding"  0.93
      "Does the robber ALLOW production?"    -> hit "does the robber BLOCK"   0.93
      "discard with MORE than 9 cards?"      -> "MORE than 7 cards"           0.93
      "robber on a DIFFERENT hex?"           -> hit "on the SAME hex"         0.97
      "do I GAIN a victory point?"           -> "do I LOSE a victory point"   0.95
      "longest road INCLUDE broken roads?"   -> "EXCLUDE broken roads"        0.95
      "kept FACE UP?"                        -> "kept FACE DOWN"              0.99
      "robber let me STEAL a card?"          -> "let me GIVE a card"          0.93
      "play proceed CLOCKWISE?"              -> "proceed COUNTERCLOCKWISE"    0.95
      "does the FIRST player go first?"      -> "does the LAST player"        0.93
      "trade with the bank INVALID?"         -> "with the bank VALID"         0.96
      "robber sit on an EMPTY hex?"          -> "sit on an OCCUPIED hex"      0.93
      "does the HIGHEST roll go first?"      -> "does the LOWEST roll"        0.92

  This is a finite list against an open-ended problem: any antonym pair whose swap
  leaves the wording — and so the embedding — almost unchanged is a candidate, and
  new ones surface as the corpus grows. The scope stays bounded because a swap only
  survives the direct-hit floor when the rest of the phrasing is near-identical, so
  the dangerous pairs are single-token antonyms that actually occur in rules
  questions; the sweeps that found `same`/`different`, `gain`/`lose`,
  `include`/`exclude`, `open`/`closed`, `clockwise`/`counterclockwise`,
  `first`/`last`, `steal`/`give`, `face up`/`face down`, `empty`/`occupied` and
  `highest`/`lowest` cover the common ones. `valid`/`invalid` is a flip too, but
  `invalid` carries negation and so is handled by `Polarity` alongside `illegal`,
  not by an axis here.

  Three classes are deliberately left UNGATED, because the word that would flip the
  answer is also the word a harmless paraphrase swaps, and blocking it bills every
  rephrase at full price:

    * `add`/`remove` — "add a road" is neutral phrasing far more often than a flip.
    * person / possessor — "do I" / "do you" / "does a player" are each other's most
      common paraphrase; the rare "my hex" vs "their hex" flip is not worth gating
      the whole pronoun space (measured: "my" vs "opponent" drops to 0.86 anyway).
    * scope and quantifier — "per turn" vs "per game", "each" vs "any": the deciding
      tokens (turn, game, each, any, every) are common and freely interchangeable.

  A round-7 sweep turned up more single-token flips that stay above the 0.92 floor
  but are left ungated for the same reason — the deciding word doubles as neutral
  phrasing, so gating it would bill honest paraphrases:

    * `left`/`right` (0.96) — "left" also means REMAINING ("how many cards are LEFT
      in the deck"), so it cannot be treated as a direction pole.
    * `once`/`twice` (0.97) — "once" also means WHEN ("ONCE you roll a seven"), so
      mapping it to the count 1 would false-gate a legitimate timing paraphrase.
    * `raise`/`lower` (0.94) — "raise" also means UPGRADE ("raise a settlement to a
      city"), a neutral action, not a value direction.
    * `own`/`opponent's`, `friendly`/`enemy` (0.92-0.94) — the possessor class again.
    * `buy`/`build` (0.93), `ahead`/`behind` (0.94), `immediately`/`later` (0.94),
      `forward`/`backward` (0.94), `north`/`south` (0.97), `adjacent`/`distant`
      (0.92) — either not true antonyms (buy/build), polysemous (behind/backward),
      contrived opposites whose natural form is a negation (adjacent vs NOT adjacent,
      already covered by `Polarity`), or too rare in the corpus to earn a gate.

  `face up`/`face down` is gated as a PHRASE, not on the bare tokens up/down, which
  carry no direction of their own ("up to seven cards").

  The first of those served "**No.** Trading before rolling is not permitted." to
  a player asking whether they may trade after rolling — which they may, every
  turn. Each pair differs by ONE token, and it is exactly the token an embedding
  compresses away: a function word, a modal, a comparative, a number. Swap a NOUN
  instead ("knight" for "monopoly", "settlement" for "city") and similarity falls
  to ~0.70 and the pool correctly misses. Content words are safe. The small words
  are not, and the small words are the ones carrying the rule.

  So the axes below are not a list of everything a question means — they are the
  tokens whose flip flips the answer while leaving the embedding where it was.

  A mismatch DROPS the candidate. The ask then proceeds to the LLM and buys a
  correct answer at full price (~$0.005). That is the cheap direction, and it is
  the direction we take whenever in doubt: a wrongly-dropped candidate costs half
  a cent, and a wrongly-kept one tells a player the opposite of the rule.
  """

  alias RuleMaven.LLM.Polarity

  # Both sides of each axis. A question carrying markers from one side is
  # incompatible with a question carrying markers from the other.
  #
  # Only SIDED axes appear here: a word earns its place by having an opposite that
  # flips the answer. "during", "turn", "player" have no opposite and so decide
  # nothing.
  @axes %{
    # "trade BEFORE rolling" (no) vs "trade AFTER rolling" (yes)
    temporal: [
      ~w(before prior preceding beforehand),
      ~w(after following subsequent afterward afterwards)
    ],
    # "CAN I move the robber" (permission) vs "MUST I move the robber" (obligation)
    modal: [
      ~w(may can could allowed permitted optional able optionally),
      ~w(must mandatory required require requires obligated forced need needs)
    ],
    # "MORE than seven cards" (discard) vs "FEWER than seven cards" (do not)
    comparative: [
      ~w(more greater above over exceed exceeds least),
      ~w(fewer less below under most)
    ],
    # "does the robber BLOCK production" vs "does the robber ALLOW production"
    permission_verb: [
      ~w(allow allows allowed permit permits permitted enable enables produce produces),
      ~w(block blocks blocked prevent prevents prevented stop stops halt halts)
    ],
    # "robber on the SAME hex" vs "robber on a DIFFERENT hex". These stay 0.97
    # apart on the embedding — one token, and the answer inverts. "another" sits
    # on the DIFFERENT side, so "another settlement" and "a different settlement"
    # agree (both right) and a real paraphrase survives; only same-vs-different
    # opposition fires.
    identity: [
      ~w(same identical unchanged),
      ~w(different another separate distinct)
    ],
    # "do I GAIN a victory point" vs "do I LOSE a victory point"; "do I WIN at
    # ten" vs "do I LOSE at ten". `add`/`remove` are deliberately excluded — too
    # common in neutral phrasing ("add a road") to swap an answer reliably.
    value_direction: [
      ~w(gain gains gained earn earns earned win wins won),
      ~w(lose loses lost forfeit forfeits forfeited)
    ],
    # "does the longest road INCLUDE broken segments" vs "EXCLUDE" / "IGNORE".
    inclusion: [
      ~w(include includes including included count counts counted counting),
      ~w(exclude excludes excluding excluded ignore ignores ignored ignoring)
    ],
    # "is trading OPEN before rolling" vs "CLOSED". Narrow but observed at 0.94.
    state: [
      ~w(open opens opened),
      ~w(closed closes closing shut)
    ],
    # "does play go CLOCKWISE" vs "COUNTERCLOCKWISE". Direction of play — one
    # token, and it is the whole answer. Near-zero paraphrase collision: you
    # only write a direction when the direction IS the question.
    direction: [
      ~w(clockwise),
      ~w(counterclockwise anticlockwise widdershins)
    ],
    # "does the FIRST player go first" vs "the LAST player". Turn order.
    # "starting"/"initial" are left off the FIRST side on purpose — they are
    # common neutral paraphrases of "first" and gating them would over-block.
    order: [
      ~w(first earliest),
      ~w(last final latest)
    ],
    # "does the robber let me STEAL a card" vs "GIVE a card". A transfer that
    # reverses direction. Kept narrow to the two distinctive verbs — "take"
    # and "pay" appear too often neutrally ("take your turn", "pay the cost").
    transfer: [
      ~w(steal steals stole stolen),
      ~w(give gives gave given)
    ],
    # "kept FACE UP" vs "FACE DOWN" — hidden vs public information, the whole
    # point of a card game's secrecy, and 0.99 on the embedding. `tokens/1`
    # collapses the phrase "face up" -> "faceup" so the BARE tokens up/down
    # stay ungated ("up to seven cards" must not fire this).
    visibility: [
      ~w(faceup revealed visible public exposed),
      ~w(facedown hidden concealed secret)
    ],
    # "can the robber sit on an EMPTY hex" vs "an OCCUPIED hex" — whether a space
    # holds a piece is the whole question of robber placement and building spots,
    # and it stays 0.93 on the embedding. Kept to the distinctive occupancy words:
    # "full"/"taken" are left off because they carry other senses ("full hand",
    # "take a card") that appear constantly in neutral phrasing.
    occupancy: [
      ~w(empty vacant unoccupied),
      ~w(occupied)
    ],
    # "the HIGHEST roll goes first" vs "the LOWEST roll" — a superlative that
    # decides a roll-off, most points, most knights. `most`/`least` are NOT here
    # on purpose: `comparative` already uses them for the at-most/at-least bound
    # ("at least seven" = seven-or-more), which is a different sense, and a token
    # cannot sit on two axes without firing both.
    superlative: [
      ~w(highest greatest largest biggest),
      ~w(lowest smallest)
    ]
  }

  @words %{
    "zero" => 0,
    "one" => 1,
    "two" => 2,
    "three" => 3,
    "four" => 4,
    "five" => 5,
    "six" => 6,
    "seven" => 7,
    "eight" => 8,
    "nine" => 9,
    "ten" => 10,
    "eleven" => 11,
    "twelve" => 12,
    "thirteen" => 13,
    "fourteen" => 14,
    "fifteen" => 15,
    "sixteen" => 16,
    "seventeen" => 17,
    "eighteen" => 18,
    "nineteen" => 19,
    "twenty" => 20,
    "thirty" => 30,
    "forty" => 40,
    "fifty" => 50
  }

  @doc """
  True when a pooled answer for `candidate` may be served to someone who asked
  `question`.

  Negation is delegated to `Polarity`, which treats an ABSENT negation as
  positive — it is a two-valued axis and a missing "not" is itself evidence.

  Every other axis is three-valued, and an absent marker is silence rather than
  evidence: only markers from OPPOSITE sides of an axis prove a flip. "How many
  cards must be discarded on a 7?" and "How many cards do I discard on a 7?" are
  the same question, and one of them simply does not mention obligation — that is
  not a disagreement, and blocking it would cost a pool hit to learn nothing.
  """
  def compatible?(question, candidate) do
    q = tokens(question)
    c = tokens(candidate)

    Polarity.compatible?(question, candidate) and
      numbers_agree?(q, c) and
      ratios_agree?(question, candidate) and
      Enum.all?(Map.keys(@axes), &axis_agrees?(&1, q, c))
  end

  @doc """
  True when a normalizer rewrite still asks the ORIGINAL question.

  The normalizer is handed the 20 nearest canonical questions as hints, and the
  nearest canonical question to "Can a player trade AFTER rolling?" is "Can a
  player trade BEFORE rolling?" — so the hint list is itself a standing invitation
  to snap a question onto its opposite. It has done exactly this before ("how is
  the robber moved" was rewritten into "is it moved after discarding", a different
  question) and the asker never sees it, because the UI displays the NORMALIZED
  text. The prompt is told to preserve polarity; this does not depend on it
  obeying.

  Numbers get a SUBSET rule rather than an equality one, because dropping a number
  is a legitimate rewrite and introducing one never is: "If I roll a 7 and I have
  8 cards, how many do I discard?" properly canonicalizes to "How many cards must
  be discarded on a 7?" (the 8 is a premise, and the ignored-premise guard is what
  covers it). Turning "discarded on an 8" into "discarded on a 7", on the other
  hand, invents the very fact under dispute.
  """
  def preserved_in_rewrite?(raw, rewrite) do
    r = tokens(raw)
    w = tokens(rewrite)

    Polarity.compatible?(raw, rewrite) and
      MapSet.subset?(numbers(w), numbers(r)) and
      MapSet.subset?(unit_numbers(w), unit_numbers(r)) and
      MapSet.subset?(ratios(rewrite), ratios(raw)) and
      Enum.all?(Map.keys(@axes), &axis_agrees?(&1, r, w))
  end

  @doc """
  The axis on which two questions disagree, or nil when they are compatible.
  Diagnostic only — logged on a rejected candidate so a lost pool hit can be
  explained without re-deriving it.
  """
  def conflict(question, candidate) do
    q = tokens(question)
    c = tokens(candidate)

    cond do
      not Polarity.compatible?(question, candidate) -> :negation
      not numbers_agree?(q, c) -> :number
      not ratios_agree?(question, candidate) -> :ratio
      true -> Enum.find(Map.keys(@axes), &(not axis_agrees?(&1, q, c)))
    end
  end

  # Two questions disagree on an axis when each names a side and the sides differ.
  # A question that names NEITHER side (or both, e.g. "can I or must I") says
  # nothing this guard can act on.
  defp axis_agrees?(axis, q, c) do
    [left, right] = @axes[axis]

    side = fn toks ->
      {Enum.any?(toks, &(&1 in left)), Enum.any?(toks, &(&1 in right))}
    end

    case {side.(q), side.(c)} do
      {{true, false}, {false, true}} -> false
      {{false, true}, {true, false}} -> false
      _ -> true
    end
  end

  # Numbers ARE the rule in a rules question: 7 cards, 4:1, 2 dice, 10 points.
  # An embedding barely moves between "more than 7 cards" and "more than 9 cards"
  # while the answer changes completely.
  #
  # Compared as SETS, and only when BOTH questions carry numbers — a question that
  # mentions none is not disagreeing about them. A set is deliberate: the same
  # premises named in a different order ("roll a 7 with 8 cards" vs "8 cards, roll
  # a 7") must still match, so position cannot be load-bearing for loose numbers.
  #
  # That set comparison is blind to TWO things. The first is a ratio's direction:
  # "trade at 2:1" and "trade at 1:2" carry the same digits, so as sets they agree,
  # but they are opposite trades (0.97 apart on the embedding). A colon-ratio is the
  # one place the order of two numbers IS the rule, so it is checked separately by
  # `ratios_agree?/2`. The prose form ("give 3 and get 1") is left ungated on
  # purpose — parsing give/get order robustly would over-block more paraphrases
  # than the rare reversed-ratio flip is worth.
  #
  # The second is a number's UNIT. "Do I discard on a 7 with 8 cards?" and "Do I
  # discard on an 8 with 7 cards?" both carry the digit set {7,8}, so as sets they
  # agree — but the first is the discard rule (8 cards, over the limit) and the
  # second is not (7 cards, under it), and they sit 0.99 apart on the embedding.
  # The set threw away which number was the HAND SIZE and which was the DIE ROLL.
  # `unit_numbers_agree?/2` recovers exactly that binding and nothing else: it pairs
  # each number with an immediately-following unit noun from a small whitelist
  # ("8 cards" -> {8,card}) and requires those pairs to match. The whitelist is why
  # this does not reintroduce the ordering fragility the set form was chosen to
  # avoid — "roll a 7 with 8 cards" and "8 cards, roll a 7" both bind only {8,card}
  # (the 7 is followed by "with"/nothing, not a unit, so it stays a loose number),
  # while the role-swapped "roll an 8 with 7 cards" binds {7,card} and is caught.
  # A number with no unit after it falls back to the loose-set comparison unchanged.
  defp numbers_agree?(q, c) do
    nq = numbers(q)
    nc = numbers(c)

    (Enum.empty?(nq) or Enum.empty?(nc) or MapSet.equal?(nq, nc)) and
      unit_numbers_agree?(q, c)
  end

  # Number-unit pairs must line up when BOTH sides carry them — empty-safe on either
  # side exactly like the loose-set and ratio comparisons, so a question that binds
  # no number to a unit is not held to disagree about one.
  defp unit_numbers_agree?(q, c) do
    uq = unit_numbers(q)
    uc = unit_numbers(c)

    Enum.empty?(uq) or Enum.empty?(uc) or MapSet.equal?(uq, uc)
  end

  # The nouns whose count IS the rule, each plural mapped to a single canonical
  # form so "7 card" and "7 cards" (and "die"/"dice", "city"/"cities") bind the
  # same. A number is bound to a unit only when the noun sits immediately after it
  # ("8 cards" -> {8,card}). Kept to units that actually decide a board-game answer
  # — a longer list only risks binding a number to an ordinary word and
  # manufacturing a disagreement.
  @unit_canon %{
    "card" => "card",
    "cards" => "card",
    "point" => "point",
    "points" => "point",
    "resource" => "resource",
    "resources" => "resource",
    "die" => "die",
    "dice" => "die",
    "player" => "player",
    "players" => "player",
    "settlement" => "settlement",
    "settlements" => "settlement",
    "city" => "city",
    "cities" => "city",
    "road" => "road",
    "roads" => "road",
    "knight" => "knight",
    "knights" => "knight",
    "hex" => "hex",
    "hexes" => "hex",
    "tile" => "tile",
    "tiles" => "tile",
    "turn" => "turn",
    "turns" => "turn",
    "space" => "space",
    "spaces" => "space",
    "token" => "token",
    "tokens" => "token"
  }

  defp unit_numbers(tokens) do
    tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(MapSet.new(), fn [a, b], acc ->
      n = to_number(a)
      unit = Map.get(@unit_canon, b)

      if n && unit, do: MapSet.put(acc, "#{n}:#{unit}"), else: acc
    end)
  end

  # A colon-ratio is compared on the RAW text — `tokens/1` splits on the colon and
  # throws the direction away. Only fires when both sides carry a ratio; the digit
  # scan in `numbers_agree?/2` already handles a ratio vs a different one (`{4,1}`
  # vs `{2,1}`), this is only for same-digits-opposite-direction (`2:1` vs `1:2`).
  defp ratios_agree?(qtext, ctext) do
    rq = ratios(qtext)
    rc = ratios(ctext)

    Enum.empty?(rq) or Enum.empty?(rc) or MapSet.equal?(rq, rc)
  end

  defp ratios(text) do
    ~r/(\d+)\s*:\s*(\d+)/
    |> Regex.scan(to_string(text))
    |> Enum.map(fn [_, a, b] -> "#{a}:#{b}" end)
    |> MapSet.new()
  end

  defp numbers(tokens) do
    for t <- tokens, n = to_number(t), into: MapSet.new(), do: n
  end

  defp to_number(token) do
    case Map.fetch(@words, token) do
      {:ok, n} ->
        n

      :error ->
        case Integer.parse(token) do
          {n, ""} -> n
          _ -> nil
        end
    end
  end

  # Digits are kept (they carry the rule) and apostrophes dropped, so that
  # "can't"/"can’t" collapse the way Polarity collapses them.
  #
  # "face up"/"face down" collapse to single tokens first, so the visibility
  # axis fires on the PHRASE while the bare tokens up/down stay ungated — "up
  # to seven cards" must not be dragged onto a visibility pole.
  defp tokens(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/['’]/u, "")
    |> String.replace(~r/\bface\s+up\b/u, "faceup")
    |> String.replace(~r/\bface\s+down\b/u, "facedown")
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
  end
end
