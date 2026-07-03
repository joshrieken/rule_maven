defmodule RuleMaven.Extract.CleanCheck do
  @moduledoc """
  Free, deterministic verdict on one page-cleanup attempt — the cheap first
  tier of the auto-clean loop. `:accept` means the attempt looks sound and no
  LLM critic call is needed; `{:suspect, direction}` routes the attempt to the
  critic, whose typed verdict decides escalation. Suspicion is cheap (one extra
  LLM call), a wrong accept is not — so borderline cases lean suspect, mirroring
  `Extract.Gate`'s recall bias.

  Directions: `:under` — the clean was too gentle (garble survived, junky input
  returned unchanged, aggressive barely cut); `:over` — it cut too hard (shrink
  beyond the level's envelope, drop guard fired); `:both` when both fire.
  """

  alias RuleMaven.Extract.Gate

  # A line is "garble" when it has enough tokens to judge and almost none look
  # like words — OCR symbol soup a cleaner should have fixed or removed.
  @garble_line_wordish 0.3
  @garble_min_tokens 3

  # Acceptable shrink fraction (in-out)/in per level. Negative = growth (a
  # little reflow growth is normal). Outside the envelope is suspect: below the
  # floor the level didn't do its job (:under), above the cap it cut into
  # content (:over).
  @envelopes %{light: {-0.10, 0.15}, standard: {-0.10, 0.30}, aggressive: {0.10, 0.70}}

  @doc """
  Score one clean attempt. `status` is `LLM.cleanup_page`'s status atom
  (`:guard_fired` is the soft-guard variant of `:kept_raw`).
  Returns `:accept` or `{:suspect, :under | :over | :both}`.
  """
  def check(_raw, _cleaned, _level, :empty), do: :accept
  def check(_raw, _cleaned, _level, :guard_fired), do: {:suspect, :over}
  # Legacy hard-guard revert: raw was kept, nothing to judge — accept as-is.
  def check(_raw, _cleaned, _level, :kept_raw), do: :accept

  def check(raw, _cleaned, _level, :unchanged) do
    if junky?(raw), do: {:suspect, :under}, else: :accept
  end

  def check(raw, cleaned, level, :cleaned) do
    {min_shrink, max_shrink} = Map.fetch!(@envelopes, level)
    shrink = shrink(raw, cleaned)

    under? = garble_lines(cleaned) > 0 or shrink < min_shrink
    over? = shrink > max_shrink

    cond do
      under? and over? -> {:suspect, :both}
      under? -> {:suspect, :under}
      over? -> {:suspect, :over}
      true -> :accept
    end
  end

  @doc "Count of symbol-soup lines a cleaner should have fixed or dropped."
  def garble_lines(text) do
    (text || "")
    |> String.split("\n", trim: true)
    |> Enum.count(fn line ->
      length(Gate.tokens(line)) >= @garble_min_tokens and
        Gate.wordish_ratio(line) < @garble_line_wordish
    end)
  end

  # Junky raw text: garble present or overall wordishness low — a page a
  # cleaner returning it verbatim almost certainly under-cleaned.
  defp junky?(raw), do: garble_lines(raw) > 0 or Gate.wordish_ratio(raw) < 0.6

  defp shrink(raw, cleaned) do
    in_len = String.length(String.trim(raw || ""))
    out_len = String.length(String.trim(cleaned || ""))
    if in_len == 0, do: 0.0, else: (in_len - out_len) / in_len
  end
end
