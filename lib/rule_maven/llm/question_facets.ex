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

  This is a finite list against an open-ended problem: any antonym pair whose swap
  leaves the wording — and so the embedding — almost unchanged is a candidate, and
  new ones surface as the corpus grows. The scope stays bounded because a swap only
  survives the direct-hit floor when the rest of the phrasing is near-identical, so
  the dangerous pairs are single-token antonyms that actually occur in rules
  questions; the sweep that found `same`/`different`, `gain`/`lose`,
  `include`/`exclude` and `open`/`closed` covers the common ones. `add`/`remove` is
  deliberately absent: it appears too often in neutral phrasing to gate an answer.

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
  # That set comparison is blind to ONE thing: a ratio's direction. "trade at 2:1"
  # and "trade at 1:2" carry the same digits, so as sets they agree, but they are
  # opposite trades (0.97 apart on the embedding). A colon-ratio is the one place
  # the order of two numbers IS the rule, so it is checked separately by
  # `ratios_agree?/2`. The prose form ("give 3 and get 1") is left ungated on
  # purpose — parsing give/get order robustly would over-block more paraphrases
  # than the rare reversed-ratio flip is worth.
  defp numbers_agree?(q, c) do
    nq = numbers(q)
    nc = numbers(c)

    Enum.empty?(nq) or Enum.empty?(nc) or MapSet.equal?(nq, nc)
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
  defp tokens(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/['’]/u, "")
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
  end
end
