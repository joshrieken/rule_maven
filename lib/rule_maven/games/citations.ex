defmodule RuleMaven.Games.Citations do
  @moduledoc """
  Validates that an answer's citation is actually grounded in the source text it
  was generated from, rather than merely present.

  `valid?/3` checks a cited passage / page against the retrieval context (the
  `[Page N]`-prefixed chunk strings the LLM was given). A citation is valid when:

    * every claim it makes is grounded — a long-enough cited passage must appear
      in some source chunk, and a cited page must match a page present in the
      chunks; AND
    * at least one claim is positively grounded.

  This catches a hallucinated quote even when the page number happens to be
  right, and a fabricated page even when no checkable passage is given. Short,
  unverifiable passages don't *fail* validation — they just can't ground it on
  their own, so a valid page is then required.
  """

  # Passages shorter than this (normalized) are too generic to verify reliably.
  @min_needle_len 12

  # Words that describe a rule's effect/consequence. Present in the answer but
  # absent from every cited quote is a strong signal the model added a claim
  # the citation doesn't actually support.
  @trigger_words ~w(
    lowers raises increases decreases unless instead always never must cannot
    before after only if requires prevents allows forbidden mandatory optional
  )

  @doc "True if the citation is grounded in `source_chunks` (a list of strings)."
  def valid?(passage, cited_page, source_chunks) do
    valid?(passage, cited_page, source_chunks, nil)
  end

  @doc """
  Like `valid?/3`, but when `cited_source` matches a chunk's `label`
  (case-insensitive), grounding is checked against that source's chunks only.
  A `nil` or unmatched label falls back to the pooled behavior (all chunks).

  `source_chunks` accepts either a list of `%{label:, content:}` maps or plain
  strings (wrapped as `%{label: nil, content: s}` for backward compatibility).
  """
  def valid?(passage, cited_page, source_chunks, cited_source) do
    maps = to_chunk_maps(source_chunks)
    scoped = scope_chunks(maps, cited_source)

    texts = Enum.map(scoped, & &1.content)
    chunks = normalize_chunks(texts)
    has_passage = is_binary(passage) and String.trim(passage) != ""
    has_page = is_integer(cited_page)

    needle = passage_needle(passage)
    checkable_passage = has_passage and String.length(needle) >= @min_needle_len
    passage_match = checkable_passage and Enum.any?(chunks, &String.contains?(&1, needle))
    passage_bad = checkable_passage and not passage_match

    page_match = has_page and cited_page in chunk_pages(texts)
    page_bad = has_page and not page_match

    # A short passage can't ground on its own, and a bare page number is far too
    # weak to ground it either: `chunk_pages/1` only asks whether the cited page
    # appears ANYWHERE in the retrieved context, which with 10-25 chunks in play
    # is nearly always true. That let a fabricated short quote ("Draw one card")
    # ride a plausible page number to `citation_valid: true` — which is the sole
    # gate on pooling and the citation trust bonus. So when a short passage IS
    # given, require it to appear in a chunk carrying the cited page.
    short_passage_match =
      has_passage and not checkable_passage and page_match and
        Enum.any?(page_scoped_chunks(texts, cited_page), &String.contains?(&1, needle))

    grounded =
      cond do
        passage_match -> true
        # Page-only citation (no passage offered): the page must exist.
        not has_passage -> page_match
        # Passage offered but unverifiable on its own: must land on the cited page.
        not checkable_passage -> short_passage_match
        true -> false
      end

    grounded and not passage_bad and not page_bad
  end

  # Normalized chunks that carry a `[Page N]` marker for `page`.
  defp page_scoped_chunks(texts, page) when is_integer(page) do
    texts
    |> Enum.filter(fn text ->
      is_binary(text) and Regex.match?(~r/\[Page\s+#{page}\]/i, text)
    end)
    |> normalize_chunks()
  end

  defp page_scoped_chunks(_texts, _page), do: []

  @doc """
  Normalizes a model-reported `cited_source` string against the actual
  `source_chunks` labels before it's persisted or rendered. Matching is
  case-insensitive; a match returns the chunk's CANONICAL label (its stored
  casing), not the model's raw string. A `nil` cited_source, or one that
  doesn't match any known label (a hallucinated source name), returns `nil` —
  callers should fall back to a generic label (e.g. "Rulebook") in that case.
  """
  def canonical_source(nil, _source_chunks), do: nil

  def canonical_source(cited_source, source_chunks) when is_binary(cited_source) do
    target = String.downcase(cited_source)

    source_chunks
    |> to_chunk_maps()
    |> Enum.find(&(String.downcase(&1.label || "") == target))
    |> case do
      %{label: label} when is_binary(label) -> label
      _ -> nil
    end
  end

  def canonical_source(_cited_source, _source_chunks), do: nil

  @doc """
  Filters a list of `%{"quote" => , "page" => , "source" => }` citation maps
  down to the ones grounded in `source_chunks`, via `valid?/4`. Order is
  preserved; ungrounded entries are dropped silently rather than failing the
  whole list — one hallucinated citation among several good ones shouldn't
  wipe out the rest of the answer's citations.
  """
  def valid_citations(citations, source_chunks) when is_list(citations) do
    Enum.filter(citations, fn c ->
      valid?(c["quote"], c["page"], source_chunks, c["source"])
    end)
  end

  def valid_citations(_citations, _source_chunks), do: []

  defp to_chunk_maps(chunks) when is_list(chunks) do
    Enum.flat_map(chunks, fn
      %{content: _} = chunk -> [Map.put_new(chunk, :label, nil)]
      s when is_binary(s) -> [%{label: nil, content: s}]
      _ -> []
    end)
  end

  defp to_chunk_maps(_), do: []

  defp scope_chunks(chunks, nil), do: chunks

  defp scope_chunks(chunks, cited_source) when is_binary(cited_source) do
    target = String.downcase(cited_source)

    case Enum.filter(chunks, &(String.downcase(&1.label || "") == target)) do
      [] -> chunks
      scoped -> scoped
    end
  end

  defp scope_chunks(chunks, _), do: chunks

  defp passage_needle(passage) when is_binary(passage) do
    passage
    |> normalize()
    |> String.split(" ", trim: true)
    |> Enum.take(10)
    |> Enum.join(" ")
  end

  defp passage_needle(_), do: ""

  defp normalize_chunks(chunks) when is_list(chunks),
    do: chunks |> Enum.filter(&is_binary/1) |> Enum.map(&normalize/1)

  defp normalize_chunks(_), do: []

  defp chunk_pages(chunks) when is_list(chunks) do
    chunks
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn text ->
      Regex.scan(~r/\[Page\s+(\d+)\]/i, text, capture: :all_but_first)
    end)
    |> Enum.map(fn [n] -> String.to_integer(n) end)
  end

  defp chunk_pages(_), do: []

  defp normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\[page\s*\d+\]/i, " ")
    |> String.replace(~r/[^a-z0-9 ]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  True when `quote` genuinely appears in one of `texts`: the FULL normalized
  quote must be contained in a normalized chunk. The leading-words needle used
  for citation passages is not enough here — a real ten-word prefix spliced to
  a fabricated tail must not verify, because the caller is deciding whether to
  spend money on the strength of this quote and feeds it onward as a trusted
  hint. Too-short quotes can't verify and return false.
  """
  def quoted_verbatim?(quote, texts) when is_binary(quote) and is_list(texts) do
    needle = normalize(quote)

    String.length(needle) >= @min_needle_len and
      Enum.any?(normalize_chunks(texts), &String.contains?(&1, needle))
  end

  def quoted_verbatim?(_quote, _texts), do: false

  @doc """
  The subset of `quotes` that verify against `texts`, deduplicated on their
  normalized form — the same rule repeated or respelled counts once. Order
  preserved.
  """
  def distinct_verified_quotes(quotes, texts) when is_list(quotes) and is_list(texts) do
    quotes
    |> Enum.filter(&quoted_verbatim?(&1, texts))
    |> Enum.uniq_by(&normalize/1)
  end

  def distinct_verified_quotes(_quotes, _texts), do: []

  # Spelled-out numbers count as engagement — "you discard four" answers
  # "how many with 9 cards" questions that restate quantities in words.
  @number_words %{
    "zero" => "0",
    "one" => "1",
    "two" => "2",
    "three" => "3",
    "four" => "4",
    "five" => "5",
    "six" => "6",
    "seven" => "7",
    "eight" => "8",
    "nine" => "9",
    "ten" => "10",
    "eleven" => "11",
    "twelve" => "12"
  }

  @doc """
  Numeric values the `question` states that the `answer` never mentions —
  the signature of an answer that substituted the game's setup default for
  the asked state. Digits and spelled-out numbers both count as mentions; a
  ratio like "2:1" is satisfied by the exact ratio or by both components.
  Empty list means the answer engaged with every stated number.
  """
  def ignored_numbers(question, answer) when is_binary(question) and is_binary(answer) do
    mentioned = numeric_tokens(answer)

    question
    |> number_words()
    |> Enum.uniq()
    |> Enum.reject(fn token ->
      case String.split(token, ":") do
        [_single] ->
          MapSet.member?(mentioned, token)

        parts ->
          MapSet.member?(mentioned, token) or
            Enum.all?(parts, &MapSet.member?(mentioned, &1))
      end
    end)
  end

  def ignored_numbers(_question, _answer), do: []

  # Fraction words the question can assert as a premise, mapped to a canonical
  # "n/m" form. Digits-in-slash form ("1/3") is recognized separately.
  @fraction_words %{
    "half" => "1/2",
    "halves" => "1/2",
    "third" => "1/3",
    "thirds" => "1/3",
    "quarter" => "1/4",
    "quarters" => "1/4",
    "fourth" => "1/4",
    "fourths" => "1/4",
    "fifth" => "1/5",
    "fifths" => "1/5"
  }

  @doc """
  Canonical fractions the `question` asserts that the `answer` never engages —
  the fraction analogue of `ignored_numbers/2`. A player who asks "do I discard
  **a third**?" has stated a premise the answer must confirm or correct; an
  answer that merely recites the real rule ("discard half") without naming the
  third leaves the misconception standing. `ignored_numbers/2` cannot see this:
  "third"/"quarter" are not numeric tokens.

  Both spelled fractions ("a third") and slash form ("1/3") count as mentions,
  and so do percentages ("25%" / "25 percent") — a percent is a fraction premise
  in different clothes, and `ignored_numbers/2` clearing the bare digit must not
  clear the proportion claim it rode in on. Percents reduce to the same "n/m"
  canonical form as words, so "50%" and "half" are the same premise: an answer
  that says "half" engages a question that asked "50%", and the gate stays quiet
  on a premise the player got right.
  An answer that names the same fraction — whether to agree ("yes, half") or to
  correct ("no, half, not a third") — clears it, because the correction restates
  the asked fraction. Empty list means every stated fraction was engaged.
  """
  def ignored_fractions(question, answer) when is_binary(question) and is_binary(answer) do
    mentioned = fraction_tokens(answer)

    question
    |> fraction_tokens()
    |> MapSet.difference(mentioned)
    |> Enum.sort()
  end

  def ignored_fractions(_question, _answer), do: []

  # A real question asserts a handful of quantities at most; a question whose
  # answer leaves more than this many numbers unengaged is table-talk narrative
  # ("on turn 37 someone argued..."), and firing the premise retry + escalate on
  # it burns real money on noise (pen round 3, 2026-07-13: a rambling road-cost
  # question escalated to the expensive model 3/3 times).
  @max_ignored_premises 4

  @doc """
  Every stated premise — numeric value or fraction — the `answer` fails to
  engage. Union of `ignored_numbers/2` and `ignored_fractions/2`; the single
  gate the ask pipeline checks before deciding an answer recited past the
  question instead of answering it.

  Returns `[]` when more than #{@max_ignored_premises} premises are missing:
  that many unengaged numbers means the question is narrative ramble, not a
  stack of asserted premises, and the gate must not spend a retry on it.
  """
  def ignored_premises(question, answer) do
    missing = ignored_numbers(question, answer) ++ ignored_fractions(question, answer)

    if length(missing) > @max_ignored_premises, do: [], else: missing
  end

  # Unicode vulgar-fraction glyphs, canonicalized to the same "n/m" form as
  # everything else. Mobile keyboards and autocorrect produce these routinely
  # (pen round 4, 2026-07-13: "⅓" sailed past the gate unseen).
  @fraction_glyphs %{
    "½" => "1/2",
    "⅓" => "1/3",
    "⅔" => "2/3",
    "¼" => "1/4",
    "¾" => "3/4",
    "⅕" => "1/5",
    "⅖" => "2/5",
    "⅗" => "3/5",
    "⅘" => "4/5",
    "⅙" => "1/6",
    "⅚" => "5/6",
    "⅐" => "1/7",
    "⅛" => "1/8",
    "⅜" => "3/8",
    "⅝" => "5/8",
    "⅞" => "7/8",
    "⅑" => "1/9",
    "⅒" => "1/10"
  }

  @fraction_numerators %{
    "one" => "1",
    "two" => "2",
    "three" => "3",
    "four" => "4",
    "five" => "5",
    "six" => "6",
    "seven" => "7"
  }

  # "two-thirds" / "two thirds" → numerator + denominator word. Parsed before
  # the bare-word scan so the pair canonicalizes as 2/3, never 1/3-via-"thirds"
  # — a ⅔ question corrected with "not two-thirds" must clear, not refire.
  @compound_fraction ~r/\b(one|two|three|four|five|six|seven)[-\s]+(halves|half|thirds|third|quarters|quarter|fourths|fourth|fifths|fifth)\b/i

  # "half" reads as a proportion bare ("discard half of your hand"); the others
  # do not. A bare "third"/"quarter"/"fifth" is far more often an ordinal —
  # "Third: how many knights?", "I came in third place" — and counting those as
  # asserted fractions makes the gate fire on a premise the player never stated
  # (pen round 5, 2026-07-13: an enumerated 3-part question burned an escalate
  # on a phantom 1/3). Singular forms therefore need a proportion determiner in
  # front, and must not be followed by a noun that makes them ordinal anyway.
  @bare_half ~r/\b(half|halves)\b/i
  @plural_fraction ~r/\b(thirds|quarters|fourths|fifths)\b/i
  @ordinal_nouns "place|places|player|players|party|parties|person|edition|time|times|turn|turns|round|rounds|printing|game|games"
  @determined_fraction ~r/\b(?:a|an|another|the)\s+(third|quarter|fourth|fifth)\b(?!\s+(?:#{@ordinal_nouns})\b)/i

  # Canonical fraction mentions in a text: spelled words in proportion context,
  # compound pairs ("two-thirds"), unicode glyphs ("⅓"), bare "n/m" slash
  # forms, and percentages — reduced to the same n/m form as everything else, so
  # "50%" and "half" are one premise, not two (pen round 5: a TRUE "do I lose
  # 50%?" could never be cleared by an answer that said "half", so the gate kept
  # firing and eventually pushed the model into correcting a correct premise).
  defp fraction_tokens(text) do
    compounds =
      Regex.scan(@compound_fraction, text)
      |> Enum.map(fn [_, num, den] ->
        denom =
          @fraction_words |> Map.fetch!(String.downcase(den)) |> String.split("/") |> List.last()

        Map.fetch!(@fraction_numerators, String.downcase(num)) <> "/" <> denom
      end)

    # Strip matched compounds so their denominator word isn't re-counted bare.
    remainder = Regex.replace(@compound_fraction, text, " ")

    words =
      [@bare_half, @plural_fraction, @determined_fraction]
      |> Enum.flat_map(&Regex.scan(&1, remainder))
      |> Enum.map(fn [_, word] -> Map.fetch!(@fraction_words, String.downcase(word)) end)

    glyphs =
      @fraction_glyphs
      |> Enum.filter(fn {glyph, _} -> String.contains?(text, glyph) end)
      |> Enum.map(fn {_, canon} -> canon end)

    slashes = Regex.scan(~r/\d+\/\d+/, text) |> Enum.map(&hd/1)

    percents =
      Regex.scan(~r/(\d+(?:\.\d+)?)\s*(?:%|percent\b)/i, text)
      |> Enum.map(fn [_, n] -> percent_to_fraction(n) end)

    MapSet.new(compounds ++ words ++ glyphs ++ slashes ++ percents)
  end

  # "50%" → "1/2", "25%" → "1/4", "12.5%" → "1/8", "33%" → "33/100". A percent
  # is a fraction written differently; canonicalizing both to lowest terms is
  # what lets an answer phrased in words clear a premise phrased in percent.
  defp percent_to_fraction(digits) do
    {num, den} =
      case String.split(digits, ".", parts: 2) do
        [whole] -> {String.to_integer(whole), 100}
        [whole, frac] -> {String.to_integer(whole <> frac), 100 * 10 ** String.length(frac)}
      end

    d = Integer.gcd(num, den)
    "#{div(num, d)}/#{div(den, d)}"
  end

  # One entry per stated number; a ratio like "2:1" stays ONE premise.
  # The digits inside a percent belong to the proportion, not to the count guard:
  # "50%" is one premise (1/2) that `ignored_fractions/2` owns, and an answer
  # saying "half" engages it without ever writing "50". Leaving the bare 50 here
  # made the number guard re-flag a premise the fraction guard had already
  # cleared — the same escalate burn and the same false correction of a correct
  # player (pen round 5, 2026-07-13).
  @percent_expr ~r/\d+(?:\.\d+)?\s*(?:%|percent\b)/i

  defp number_words(text) do
    text
    |> String.downcase()
    |> then(&Regex.replace(@percent_expr, &1, " "))
    |> String.split(~r/[^a-z0-9:]+/, trim: true)
    |> Enum.map(&Map.get(@number_words, &1, &1))
    |> Enum.filter(&(&1 =~ ~r/^\d+(?::\d+)?$/))
  end

  # Mention set for the answer side: a ratio also mentions its components.
  defp numeric_tokens(text) do
    text
    |> number_words()
    |> Enum.flat_map(fn w ->
      if String.contains?(w, ":"), do: [w | String.split(w, ":")], else: [w]
    end)
    |> MapSet.new()
  end

  # An answer whose prose isn't plausibly grounded in its own cited quotes:
  # either it uses a consequence/causal word the quotes never state, or it's
  # much longer than the quotes could support. Cheap (no LLM call) first-pass
  # gate — a true positive here gets escalated to `LLM.critique_grounding/3`.
  def suspicious?(answer, quotes, sources \\ []), do: suspicion(answer, quotes, sources) != nil

  @doc """
  Like `suspicious?/2` but names WHICH heuristic fired: `:keyword`,
  `:numeric`, `:length_ratio`, `:legality`, or `nil` when the answer looks
  grounded. The reason is logged alongside the critic verdict so the triggers
  can be recalibrated independently against real fire/confirm rates.

  `sources` (the full retrieved chunk texts) enables the `:numeric` check. It
  is deliberately judged against the whole context rather than the cited
  quotes: quotes are condensed, so a grounded answer routinely states a number
  that appears in the chunk but not in the snippet the model chose to quote.
  Comparing against the quotes alone would fire the critic on a large fraction
  of correct answers. A number present in NO retrieved chunk, by contrast, is
  a number the model invented.
  """
  def suspicion(answer, quotes, sources \\ [])

  def suspicion(answer, quotes, sources) when is_binary(answer) do
    quotes = quotes |> List.wrap() |> Enum.filter(&is_binary/1)
    sources = sources |> List.wrap() |> Enum.filter(&is_binary/1)

    answer_norm = normalize(answer)
    combined_quote_norm = quotes |> Enum.join(" ") |> normalize()

    keyword_hit? =
      Enum.any?(@trigger_words, fn word ->
        contains_word?(answer_norm, word) and not contains_word?(combined_quote_norm, word)
      end)

    quote_word_count = combined_quote_norm |> String.split(" ", trim: true) |> length()
    answer_word_count = answer_norm |> String.split(" ", trim: true) |> length()

    length_ratio_hit? =
      quote_word_count > 0 and answer_word_count > quote_word_count * 2.5

    cond do
      keyword_hit? -> :keyword
      numeric_hit?(answer_norm, sources) -> :numeric
      length_ratio_hit? -> :length_ratio
      legality_hit?(answer) -> :legality
      true -> nil
    end
  end

  def suspicion(_answer, _quotes, _sources), do: nil

  # A yes/no legality answer is ALWAYS worth a critic call, whatever the other
  # heuristics think.
  #
  # The three cheap triggers all detect *addition* — a word, a number, or a
  # volume of prose the sources don't support. None of them can see a
  # CONTRADICTION, where the answer's words are drawn entirely from the sources
  # but its polarity is inverted. Observed in the wild: asked whether a player
  # may trade with the bank on someone else's turn, the model answered "Yes"
  # while its own citation list contained "You may not trade with the bank
  # during another player's turn." Every word was grounded, no number appeared,
  # and the answer was SHORTER than its quotes — all three triggers stayed
  # silent, and a flat reversal of the rule shipped with a valid page cite and
  # a green stamp.
  #
  # Polarity is the most damaging error the system can make (it tells players
  # to do the one thing the rulebook forbids) and it is precisely the class the
  # cheap gates are blind to, so the gate for it is unconditional rather than
  # heuristic. Scoped to the verdict LEAD, not the word "yes" anywhere in the
  # prose, so this stays a bounded extra cost on can-I questions instead of
  # "run the critic on everything".
  @legality_lead ~r/\A\s*(?:\*\*)?(?:yes|no)(?:\*\*)?\s*(?:[—–\-,.:!]|\z)/i

  defp legality_hit?(answer), do: Regex.match?(@legality_lead, answer)

  @yes_lead ~r/\A\s*(?:\*\*)?yes(?:\*\*)?\s*(?:[—–\-,.:!]|\z)/i

  # Negation forms a rulebook uses to forbid something.
  @prohibition ~r/\b(?:may not|must not|cannot|can not|may never|can never|are not allowed to|is not allowed to|do not|does not|never)\b/i

  # A negation sitting immediately before the predicate inside the ANSWER, which
  # means the answer is RESTATING the prohibition, not denying it.
  @answer_negation ~r/\b(?:not|never|cannot|no)\b[^.!?]{0,20}\z/i

  # Modal verbs are freely interchanged between the rulebook's phrasing and the
  # model's, so "you may trade" and "a player can trade" must compare equal.
  @modals ~r/\b(?:may|can|could|is able to|are able to|is permitted to|are permitted to)\b/i

  @doc """
  The cited quote that `answer` AFFIRMATIVELY CONTRADICTS, or nil.

  Catches the single most damaging output the pipeline can produce: a **Yes**
  answer whose own citation forbids the very thing it just permitted. Live
  example, reproduced 3 times out of 3 —

      Q: "Can I trade with the bank during another player's turn?"
      A: "Yes, a player can trade with the bank during another player's turn."
      cited: "You may not trade with the bank during another player's turn."

  The LLM grounding critic is shown both texts and answers "grounded", because
  every phrase in the answer really does appear in the source; support-shaped
  checking cannot see an inverted polarity. So this decides it in code instead.

  The test: the quote forbids some predicate ("trade with the bank during
  another player's turn"), and the answer leads with **Yes** and states that
  same predicate with NO negation in front of it. An answer that merely restates
  the prohibition ("No — you may not trade with the bank…"), or cites it as a
  caveat ("Yes, you may trade with players, but you may not trade with the
  bank…"), carries the negation and is left alone.
  """
  def contradicted_quote(answer, quotes) when is_binary(answer) and is_list(quotes) do
    if Regex.match?(@yes_lead, answer) do
      answer_norm = answer |> normalize() |> String.replace(@modals, "may")

      quotes
      |> Enum.filter(&is_binary/1)
      |> Enum.find(&affirmatively_contradicted?(answer_norm, &1))
    end
  end

  def contradicted_quote(_answer, _quotes), do: nil

  defp affirmatively_contradicted?(answer_norm, quote) do
    quote_norm = quote |> normalize() |> String.replace(@modals, "may")

    case Regex.split(@prohibition, quote_norm, parts: 2) do
      [_before, predicate] ->
        predicate = predicate |> String.trim() |> significant_predicate()

        predicate != "" and asserted_without_negation?(answer_norm, predicate)

      _ ->
        false
    end
  end

  # The first clause of what the rule forbids. Long enough to be specific (a
  # two-word predicate would collide across unrelated rules), capped so a
  # trailing subordinate clause the answer happens to omit can't defeat the
  # match.
  @predicate_words 8
  @min_predicate_words 3

  defp significant_predicate(predicate) do
    words =
      predicate
      |> String.split(~r/[.,;:!?]/, parts: 2)
      |> List.first()
      |> String.split(" ", trim: true)
      |> Enum.take(@predicate_words)

    if length(words) >= @min_predicate_words, do: Enum.join(words, " "), else: ""
  end

  # Does the answer state `predicate` at least once with no negation immediately
  # before it? A negated occurrence means the answer agrees with the rule.
  defp asserted_without_negation?(answer_norm, predicate) do
    case :binary.matches(answer_norm, predicate) do
      [] ->
        false

      matches ->
        Enum.any?(matches, fn {start, _len} ->
          preceding = binary_part(answer_norm, 0, start)
          not Regex.match?(@answer_negation, preceding)
        end)
    end
  end

  # Spelled forms the model uses interchangeably with digits, so "3 cards" is
  # not treated as ungrounded when the quote says "three cards".
  @number_words %{
    "one" => "1",
    "two" => "2",
    "three" => "3",
    "four" => "4",
    "five" => "5",
    "six" => "6",
    "seven" => "7",
    "eight" => "8",
    "nine" => "9",
    "ten" => "10",
    "twelve" => "12"
  }

  # A quantity asserted by the answer but present in NO retrieved chunk. Wrong
  # numbers were the single largest hole in the grounding net: neither
  # @trigger_words (no digits) nor the length ratio (a short, confident "You get
  # 3 action points per turn." is not verbose) can fire, so a fabricated count
  # reached the user, got pooled, and earned a citation trust bonus without any
  # critic ever running.
  #
  # With no sources to check against there is nothing to judge, so the trigger
  # stays silent rather than firing on every answer that mentions a number.
  defp numeric_hit?(_answer_norm, []), do: false

  defp numeric_hit?(answer_norm, sources) do
    source_numbers = sources |> Enum.join(" ") |> normalize() |> numbers_in()

    answer_norm
    |> numbers_in()
    |> Enum.any?(&(&1 not in source_numbers))
  end

  defp numbers_in(text) do
    digits = Regex.scan(~r/\b\d+\b/, text) |> Enum.map(fn [n] -> n end)

    words =
      @number_words
      |> Enum.filter(fn {word, _digit} -> contains_word?(text, word) end)
      |> Enum.map(fn {_word, digit} -> digit end)

    MapSet.new(digits ++ words)
  end

  # Smallest normalized word count an answer may keep after a clause strip —
  # below this the salvage would gut the answer, so the caller should refuse.
  @min_salvaged_words 8

  @doc """
  Removes a critic-flagged unsupported clause from `answer`, keeping the rest.

  Tries an exact substring removal first; failing that, drops each line whose
  normalized text matches (contains or is contained by) the normalized clause,
  so markdown decoration in the answer doesn't defeat the match. Returns
  `{:ok, stripped}` only when the clause was actually located AND enough
  substantive answer remains; `:error` means the caller should fall back to a
  full refusal.
  """
  def strip_unsupported_clause(answer, clause) when is_binary(answer) and is_binary(clause) do
    clause = String.trim(clause)

    with false <- clause == "",
         {:ok, stripped} <- remove_clause(answer, clause),
         true <- substantive?(stripped) do
      {:ok, tidy(stripped)}
    else
      _ -> :error
    end
  end

  def strip_unsupported_clause(_answer, _clause), do: :error

  defp remove_clause(answer, clause) do
    if String.contains?(answer, clause) do
      {:ok, String.replace(answer, clause, "")}
    else
      remove_matching_lines(answer, normalize(clause))
    end
  end

  defp remove_matching_lines(_answer, ""), do: :error

  defp remove_matching_lines(answer, clause_norm) do
    lines = String.split(answer, "\n")

    kept =
      Enum.reject(lines, fn line ->
        case normalize(line) do
          "" -> false
          norm -> String.contains?(norm, clause_norm) or String.contains?(clause_norm, norm)
        end
      end)

    if length(kept) == length(lines), do: :error, else: {:ok, Enum.join(kept, "\n")}
  end

  defp substantive?(stripped) do
    word_count = stripped |> normalize() |> String.split(" ", trim: true) |> length()
    word_count >= @min_salvaged_words
  end

  defp tidy(text) do
    text
    # Bullet/heading stubs left when only part of a line was removed.
    |> String.replace(~r/^\s*(?:[-*•]|\d+\.)\s*$/m, "")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp contains_word?(text, word) do
    Regex.match?(~r/\b#{Regex.escape(word)}\b/, text)
  end
end
