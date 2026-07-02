defmodule RuleMaven.Extract.Gate do
  @moduledoc """
  Quality gate for page extraction — the accuracy/cost engine.

  Two cheap, independent reads of a page (text layer or OCR vs. cheap vision)
  are scored here. Strong agreement means the page is at its accuracy ceiling: a
  stronger (costly) model can't change a result two independent methods already
  concur on, so we stop. Disagreement is the *only* place escalation can change
  the answer, so the gate is **recall-biased** — when in doubt, escalate. A
  wasted escalation costs money but no accuracy; a skipped one costs accuracy, so
  the asymmetry is deliberate.

  Pure and dictionary-free: signals are agreement (token-set overlap), coverage
  (length parity, the silent-drop catcher), and wordishness (symbol-soup
  detector). Calibration with a real lexicon is a later phase.
  """

  # Token-set agreement at/above this → the two readers concur; trust, don't escalate.
  @agree_threshold 0.75
  # Length parity below this → one reader dropped content the other kept; escalate.
  @coverage_threshold 0.7
  # A clean text layer needs at least this wordish ratio to be trusted without a
  # second reader (skips a vision call on born-digital pages — the cost win).
  # Calibrated at 0.75: measured across 3 rulebooks, genuine born-digital prose
  # scores wordish 0.60–0.83 (numbers, icons, card codes drag it down) yet agrees
  # with vision 32/32 pages. The old 0.85 never fired on real text, so the
  # skip-vision fast-path was dead code and every clean page paid a redundant
  # cross-check. The residual risk (a wordish-looking page that silently dropped
  # content) is caught by drift-sampling trusted pages — see decide_page/4.
  @clean_layer_wordish 0.75
  # Floor on token count: below this there's too little text to trust on structure
  # alone (a near-empty/caption page), so cross-check it — the insurance is cheap.
  @clean_layer_min_tokens 12

  @doc """
  Lowercased alphanumeric token list for a chunk of text.
  """
  def tokens(text) do
    (text || "")
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.map(&String.downcase/1)
  end

  @doc """
  Fraction of tokens that look like real words (start with a letter, 3+ letters,
  contain a vowel). Low ratio = OCR symbol soup / decorative-font garble.
  """
  def wordish_ratio(text) do
    toks = String.split(text || "", ~r/\s+/, trim: true)

    case length(toks) do
      0 -> 0.0
      total -> Enum.count(toks, &wordish_token?/1) / total
    end
  end

  defp wordish_token?(tok) do
    # Strip leading/trailing punctuation ("crafts," "sports." "activities:") so
    # ordinary punctuated prose still counts as wordish.
    core = String.replace(tok, ~r/^\p{P}+|\p{P}+$/u, "")

    Regex.match?(~r/^[A-Za-z][A-Za-z'’-]{2,}$/u, core) and
      Regex.match?(~r/[aeiouAEIOUyY]/, core)
  end

  @doc """
  Token-set Jaccard overlap between two reads (0.0–1.0). The core agreement
  signal: high overlap means two independent methods produced the same words.
  """
  def agreement(a, b) do
    sa = MapSet.new(tokens(a))
    sb = MapSet.new(tokens(b))

    cond do
      MapSet.size(sa) == 0 and MapSet.size(sb) == 0 -> 1.0
      MapSet.size(sa) == 0 or MapSet.size(sb) == 0 -> 0.0
      true -> MapSet.size(MapSet.intersection(sa, sb)) / MapSet.size(MapSet.union(sa, sb))
    end
  end

  @doc """
  Length parity (shorter token count / longer). Near 1.0 = both reads saw the
  same amount of text; low = one dropped a chunk (a table, a column) the other
  kept. The silent-drop catcher.
  """
  def coverage(a, b) do
    la = length(tokens(a))
    lb = length(tokens(b))

    cond do
      la == 0 and lb == 0 -> 1.0
      la == 0 or lb == 0 -> 0.0
      true -> min(la, lb) / max(la, lb)
    end
  end

  @doc """
  Is this text layer clean enough to trust on its own — no second reader needed?
  True only for clearly-wordish, non-trivial text (born-digital pages). Anything
  borderline returns false and gets cross-checked, per the recall bias.
  """
  def clean_text_layer?(layer) do
    trimmed = String.trim(layer || "")

    trimmed != "" and length(tokens(trimmed)) >= @clean_layer_min_tokens and
      wordish_ratio(trimmed) >= @clean_layer_wordish
  end

  @doc """
  Majority vote over N independent reads of one page. Returns `{:ok, text}` when
  any two reads agree at/above `threshold` (token-set Jaccard) — the richer of the
  first such agreeing pair — else `:none`. The cheap adjudicator for the mid
  escalation tier: two of three reads concurring settles the page without paying
  for the adversarial critic; only genuine three-way conflict escalates further.

  A failed read (`""`) never votes here: unlike `assess/2`'s both-empty case
  (where two *original* T1 readers genuinely saw the page), by the time
  `majority/2,3` runs the page has already failed to settle at T1 — so an empty
  string reaching this function means a dead read, not a confirmed-blank page.
  Two dead reads "agreeing" with each other would silently settle a page that
  actually had content (the reader that saw it just isn't in the empty pair).
  So any pair containing an empty read is skipped, including all-empty input.

  `exclude_pairs` (index pairs into `reads`, order-independent) lets a caller
  keep a specific pair from voting — e.g. the original T1 pair that already
  disagreed on a fuller test (coverage/wordish, not just raw agreement) should
  not be allowed to re-settle the page on the strength of that same stale
  comparison; a fresh read must corroborate it.
  """
  def majority(reads, threshold, opts \\ []) when is_list(reads) do
    exclude = opts |> Keyword.get(:exclude_pairs, []) |> Enum.map(&normalize_pair/1) |> MapSet.new()

    pairs =
      for {a, i} <- Enum.with_index(reads),
          {b, j} <- Enum.with_index(reads),
          i < j,
          String.trim(a || "") != "",
          String.trim(b || "") != "",
          not MapSet.member?(exclude, normalize_pair({i, j})),
          do: {a, b}

    Enum.find_value(pairs, :none, fn {a, b} ->
      if agreement(a, b) >= threshold, do: {:ok, richer(a, b)}
    end)
  end

  defp normalize_pair({i, j}) when i <= j, do: {i, j}
  defp normalize_pair({i, j}), do: {j, i}

  # Richer of two reads: more real-word content (wordishness × token count), raw
  # length as tiebreak. Mirrors the private picker in RulebookDownloader.
  defp richer(a, b) do
    score = fn t -> {wordish_ratio(t) * length(tokens(t)), String.length(t)} end
    if score.(a) >= score.(b), do: a, else: b
  end

  @doc """
  Score two independent reads of one page. Returns `%{confidence, agree?,
  escalate?, signals}`. `agree?` true when the readers strongly concur (stop);
  `escalate?` true when a costly re-read could change the answer.

  Both-empty is treated as agreement that the page has no text (a blank/art page)
  — confidence is moderate and we do NOT escalate forever on a genuinely empty
  page.
  """
  def assess(a, b) do
    agr = agreement(a, b)
    cov = coverage(a, b)
    wa = wordish_ratio(a)
    wb = wordish_ratio(b)
    best_wordish = max(wa, wb)

    signals = %{agreement: agr, coverage: cov, wordish_a: wa, wordish_b: wb}

    both_empty? = String.trim(a || "") == "" and String.trim(b || "") == ""

    cond do
      both_empty? ->
        %{confidence: 0.6, agree?: true, escalate?: false, signals: signals}

      agr >= @agree_threshold and cov >= @coverage_threshold and best_wordish >= 0.5 ->
        # Two independent readers concur and neither dropped content — ceiling.
        %{
          confidence: confidence(agr, cov, best_wordish),
          agree?: true,
          escalate?: false,
          signals: signals
        }

      true ->
        # Disagreement, a drop, or garble — only place a stronger model helps.
        %{
          confidence: confidence(agr, cov, best_wordish),
          agree?: false,
          escalate?: true,
          signals: signals
        }
    end
  end

  # Blended confidence, weighted toward agreement (the strongest signal).
  defp confidence(agr, cov, wordish) do
    Float.round(0.6 * agr + 0.25 * cov + 0.15 * wordish, 3)
  end
end
