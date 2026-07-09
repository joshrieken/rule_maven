defmodule RuleMaven.ThemePalette do
  @moduledoc """
  Builds a full CSS-variable theme from a handful of anchor colors extracted from
  a game's cover art.

  The vision model is only asked for four anchors per variant — `accent`, `bg`,
  `surface`, `text` — and everything else (borders, muted text, header gradient,
  hover shadows, accent shades) is **derived deterministically** here. Two reasons:

    * the prompt stays tiny and the model can't drift across 26 hand-tuned values, and
    * we can force WCAG contrast on the text colors so an auto-generated theme is
      always legible, no matter how garish the cover is.

  Output shape (stored on `games.theme_palette`):

      %{"light" => %{"--bg" => "#…", …}, "dark" => %{"--bg" => "#…", …}}

  matching the `[data-theme="…"]` variable blocks hand-authored in `app.css`.
  """

  # Near-black the header gradient is built on; accent is mixed in for a hint of
  # the game's hue while staying dark enough for the white-text header design.
  @header_dark {24, 22, 20}
  # Bright gold for the header icon glow + GM badge background.
  @header_gold {232, 197, 82}

  # Semantic status colors kept constant per scheme so "danger is red" survives
  # whatever the cover's palette is. Tuned to read on the respective backgrounds.
  @semantic %{
    "light" => %{
      "--yellow" => "#B8960F",
      "--red" => "#C83030",
      "--red-bg" => "#FFF0F0",
      "--green" => "#2A8040",
      "--blue" => "#3060C0"
    },
    "dark" => %{
      "--yellow" => "#E0C060",
      "--red" => "#E86060",
      "--red-bg" => "#2E1C18",
      "--green" => "#5CB075",
      "--blue" => "#6090E0"
    }
  }

  @doc """
  Build the `%{"light" => vars, "dark" => vars}` palette from the anchor map the
  vision model returns. Returns `{:ok, palette}` or `{:error, reason}` when the
  anchors are missing/malformed for either scheme.
  """
  def build(%{"light" => light, "dark" => dark}) do
    with {:ok, l} <- build_variant(light, :light),
         {:ok, d} <- build_variant(dark, :dark) do
      {:ok, %{"light" => l, "dark" => d}}
    end
  end

  def build(_), do: {:error, :missing_variants}

  defp build_variant(anchors, scheme) when is_map(anchors) do
    with {:ok, accent} <- fetch(anchors, "accent"),
         {:ok, bg} <- fetch(anchors, "bg"),
         {:ok, surface} <- fetch(anchors, "surface"),
         {:ok, text} <- fetch(anchors, "text") do
      {:ok, derive(accent, bg, surface, text, scheme)}
    end
  end

  defp build_variant(_, _), do: {:error, :bad_anchors}

  defp fetch(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) ->
        case parse(v) do
          {:ok, rgb} -> {:ok, rgb}
          :error -> {:error, {:bad_color, key}}
        end

      _ ->
        {:error, {:missing_color, key}}
    end
  end

  # Contrast floors for the de-emphasized text tiers, checked against every
  # background they can land on (--bg, --bg-surface, --bg-subtle). Calibrated
  # to the hand-authored Midnight theme (~6.1 secondary / ~4.6 muted at worst)
  # rather than bare WCAG minimums — 4.5:1 is also AA for the small sizes this
  # app renders muted text at.
  @secondary_ratio 6.0
  @muted_ratio 4.5

  # Button labels sit ON the accent; AA-large isn't enough for the small bold
  # labels this app uses, and a mid-tone accent caps out well below it anyway.
  @fill_ratio 7.0

  defp derive(accent, bg, surface, text, scheme) do
    # A mid-luminance accent (mustard gold, dusty teal) can't be fixed by text
    # choice alone — pure black tops out around 5.8:1 on it. Lift the fill
    # itself toward the extreme opposite its text until the label clears
    # @fill_ratio, then derive every accent shade from the lifted color so the
    # theme stays coherent.
    {accent, accent_text} = readable_fill(accent)

    # On dark schemes "toward background" means lighter borders / muted text;
    # the math is the same (mix text into bg) because text already contrasts bg.
    text = ensure_contrast(text, bg, 7.0)
    on_surface = ensure_contrast(text, surface, 7.0)
    bg_subtle = mix(bg, accent, 0.08)
    backgrounds = [bg, surface, bg_subtle]

    shadow =
      case scheme do
        :light -> "rgba(0, 0, 0, 0.06)"
        :dark -> "rgba(0, 0, 0, 0.40)"
      end

    %{
      "--bg" => hex(bg),
      "--bg-surface" => hex(surface),
      "--bg-subtle" => hex(bg_subtle),
      "--bg-danger" => @semantic[scheme_key(scheme)]["--red-bg"],
      "--text" => hex(on_surface),
      "--text-heading" => hex(ensure_contrast(darken_toward_text(text, scheme), surface, 7.0)),
      "--text-secondary" =>
        hex(ensure_contrast_all(mix(text, bg, 0.40), backgrounds, @secondary_ratio)),
      "--text-muted" => hex(ensure_contrast_all(mix(text, bg, 0.58), backgrounds, @muted_ratio)),
      "--border" => hex(mix(text, bg, 0.78)),
      "--border-strong" => hex(mix(text, bg, 0.62)),
      "--border-subtle" => hex(mix(text, bg, 0.88)),
      "--accent" => hex(accent),
      # Foreground for text/icons placed ON the accent color (buttons, the user
      # chat bubble). Black or white, whichever reads — a vivid light accent
      # (e.g. yellow) keeps its color as a link on the page but flips to dark
      # text when used as a fill. Defaults to #fff in static themes via
      # `var(--accent-text, #fff)`, so only generated themes need this.
      "--accent-text" => hex(accent_text),
      # Accent used AS text/icons on the page background (labels, links, the
      # "Overview" pill). A vivid light accent (yellow) is illegible as text on a
      # light surface, so darken/lighten it until it reads. Defaults to --accent
      # in static themes (whose accents already contrast), so only generated
      # themes shift. Borders/fills keep the vivid --accent.
      "--accent-ink" => hex(readable_text(accent, surface, 4.5)),
      "--accent-dark" => hex(darken(accent, 0.18)),
      "--accent-light" => hex(lighten(accent, 0.20)),
      "--accent-subtle" => hex(mix(bg, accent, 0.12)),
      "--shadow" => shadow,
      "--shadow-hover" => rgba(accent, 0.18),
      # Text-selection highlight. Plain --accent isn't guaranteed to stand out
      # against --bg (e.g. a dark red accent on a near-black cover reads as
      # barely-there), so push it until it clears contrast, then pick
      # black/white to sit on top of *that* — not the raw accent.
      "--selection-bg" => hex(ensure_contrast(accent, bg, 7.0)),
      "--selection-text" => hex(readable_on(ensure_contrast(accent, bg, 7.0))),
      # The header is always a dark, lightly accent-tinted gradient — like every
      # static theme. The whole header design (white text, glowing yellow icon,
      # the "Maven" gradient) assumes a dark bar, so we mix the accent into a
      # near-black rather than just darkening it, which would leave a bright
      # accent (e.g. yellow) header that looks garish and washes out the text.
      "--header-bg-start" => hex(mix(@header_dark, accent, 0.22)),
      "--header-bg-end" => hex(mix(@header_dark, accent, 0.10)),
      # Bright gold for the icon glow + GM badge. The header is always dark, so a
      # vivid gold reads well and gives the badge (dark text on it) real contrast
      # — the muted semantic yellow was too dark for that.
      "--header-border" => hex(@header_gold),
      "--focus-ring" => rgba(accent, 0.18)
    }
    |> Map.merge(@semantic[scheme_key(scheme)])
  end

  defp scheme_key(:light), do: "light"
  defp scheme_key(:dark), do: "dark"

  # Pick black or white text for use ON `color`, whichever has better contrast.
  # Prefers a slightly-off near-black so it never looks harsher than the rest
  # of the UI — but a mid-luminance accent (e.g. a mustard gold) gives the soft
  # tone only ~4.7:1, so when it can't clear 6:1 we escalate to the pure
  # extreme with the better ratio instead of shipping a muddy button label.
  defp readable_on(color) do
    soft_dark = {26, 26, 26}

    cond do
      contrast(soft_dark, color) >= 6.0 ->
        soft_dark

      contrast({0, 0, 0}, color) >= contrast({255, 255, 255}, color) ->
        {0, 0, 0}

      true ->
        {255, 255, 255}
    end
  end

  # Pick the label color for an accent fill, then — when even that pairing
  # can't clear @fill_ratio — lift the fill itself toward the extreme opposite
  # the label (a muddy mustard brightens, a washed-out mid-grey-blue darkens or
  # brightens per its label). Mixing toward an extreme preserves the hue's
  # direction, so an Ethnos gold stays gold, just vivid enough to carry text.
  # Returns `{fill, label}`.
  defp readable_fill(accent) do
    label = readable_on(accent)

    if contrast(label, accent) >= @fill_ratio do
      {accent, label}
    else
      away = if luminance(label) < 0.5, do: {255, 255, 255}, else: {0, 0, 0}
      {step_toward(accent, label, away, @fill_ratio, 0), label}
    end
  end

  # Nudge `color` toward black (on a light bg) or white (on a dark bg) until it
  # reads as text against `bg` at `ratio`. Keeps the hue, just deepens/lightens
  # it — a light yellow accent becomes a dark gold that's legible as a label.
  defp readable_text(color, bg, ratio) do
    target = if luminance(bg) > 0.5, do: {0, 0, 0}, else: {255, 255, 255}
    step_toward(color, bg, target, ratio, 0)
  end

  # Headings should be a touch stronger than body: darker on light, lighter on dark.
  defp darken_toward_text({r, g, b}, :light), do: darken({r, g, b}, 0.10)
  defp darken_toward_text({r, g, b}, :dark), do: lighten({r, g, b}, 0.10)

  # ── color math ────────────────────────────────────────────────────────────

  @doc "Parse `#RGB` / `#RRGGBB` into `{:ok, {r,g,b}}` or `:error`."
  def parse(s) when is_binary(s) do
    s = s |> String.trim() |> String.trim_leading("#")

    case String.length(s) do
      6 -> parse_hex6(s)
      3 -> s |> String.graphemes() |> Enum.map_join(&(&1 <> &1)) |> parse_hex6()
      _ -> :error
    end
  end

  defp parse_hex6(s) do
    with {r, ""} <- Integer.parse(String.slice(s, 0, 2), 16),
         {g, ""} <- Integer.parse(String.slice(s, 2, 2), 16),
         {b, ""} <- Integer.parse(String.slice(s, 4, 2), 16) do
      {:ok, {r, g, b}}
    else
      _ -> :error
    end
  end

  defp hex({r, g, b}) do
    "#" <>
      (Enum.map_join(
         [r, g, b],
         &(&1 |> clamp() |> Integer.to_string(16) |> String.pad_leading(2, "0"))
       )
       |> String.upcase())
  end

  defp rgba({r, g, b}, a), do: "rgba(#{clamp(r)}, #{clamp(g)}, #{clamp(b)}, #{a})"

  defp clamp(n) when n < 0, do: 0
  defp clamp(n) when n > 255, do: 255
  defp clamp(n), do: round(n)

  # mix(a, b, t): t is the fraction of b (0.0 = all a, 1.0 = all b).
  defp mix({r1, g1, b1}, {r2, g2, b2}, t) do
    {r1 + (r2 - r1) * t, g1 + (g2 - g1) * t, b1 + (b2 - b1) * t}
  end

  defp lighten(c, t), do: mix(c, {255, 255, 255}, t)
  defp darken(c, t), do: mix(c, {0, 0, 0}, t)

  # WCAG relative luminance.
  defp luminance({r, g, b}) do
    [r, g, b]
    |> Enum.map(fn c ->
      c = c / 255

      if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
    end)
    |> then(fn [r, g, b] -> 0.2126 * r + 0.7152 * g + 0.0722 * b end)
  end

  defp contrast(c1, c2) do
    l1 = luminance(c1)
    l2 = luminance(c2)
    {hi, lo} = if l1 >= l2, do: {l1, l2}, else: {l2, l1}
    (hi + 0.05) / (lo + 0.05)
  end

  # Like ensure_contrast/3 but against several backgrounds at once: push `fg`
  # until it clears `ratio` against the worst of them. All the backgrounds a
  # text tier can land on sit on the same side (dark theme → all dark), so one
  # direction of travel satisfies them all.
  defp ensure_contrast_all(fg, bgs, ratio) do
    Enum.reduce(bgs, fg, &ensure_contrast(&2, &1, ratio))
  end

  # Push `fg` toward black or white (whichever the background allows) until it
  # clears `ratio` against `bg`, or we hit the extreme. Guarantees legibility.
  defp ensure_contrast(fg, bg, ratio) do
    if contrast(fg, bg) >= ratio do
      fg
    else
      target = if luminance(bg) > 0.5, do: {0, 0, 0}, else: {255, 255, 255}
      step_toward(fg, bg, target, ratio, 0)
    end
  end

  defp step_toward(fg, bg, target, ratio, n) when n < 20 do
    if contrast(fg, bg) >= ratio do
      fg
    else
      step_toward(mix(fg, target, 0.12), bg, target, ratio, n + 1)
    end
  end

  defp step_toward(fg, _bg, _target, _ratio, _n), do: fg

  @doc """
  Re-enforce the secondary/muted text contrast floors on an already-derived
  variant map. Palettes persisted before the floors were raised (muted was
  allowed down to 3:1, and only checked against `--bg-surface`) render dim,
  barely-readable text on dark covers — this lifts those two values in place
  from the variant's own anchors. Idempotent: freshly derived palettes pass
  through unchanged. Applied at render time so existing rows need no backfill.

  Returns the map untouched when the anchor vars are missing or unparseable.
  """
  def fix_text_contrast(%{"--bg" => b, "--bg-surface" => s} = vars) do
    with {:ok, bg} <- parse(b),
         {:ok, surface} <- parse(s),
         {:ok, secondary} <- parse(vars["--text-secondary"] || ""),
         {:ok, muted} <- parse(vars["--text-muted"] || "") do
      backgrounds =
        case parse(vars["--bg-subtle"] || "") do
          {:ok, subtle} -> [bg, surface, subtle]
          :error -> [bg, surface]
        end

      Map.merge(vars, %{
        "--text-secondary" => hex(ensure_contrast_all(secondary, backgrounds, @secondary_ratio)),
        "--text-muted" => hex(ensure_contrast_all(muted, backgrounds, @muted_ratio))
      })
    else
      _ -> vars
    end
  end

  def fix_text_contrast(vars), do: vars

  @doc """
  Recompute the `--accent` / `--accent-text` fill pairing at render time.
  Fixes palettes persisted before the fill lift existed (a muddy mid-tone
  accent under near-black text), and palettes from before `--accent-text`
  existed at all (which fell back to `#fff` via `var(--accent-text, #fff)` —
  worse). Idempotent: freshly derived palettes pass through unchanged.
  Returns the map untouched when `--accent` is missing or unparseable.
  """
  def fix_accent_text(%{"--accent" => accent} = vars) do
    case parse(accent) do
      {:ok, rgb} ->
        {fill, label} = readable_fill(rgb)
        Map.merge(vars, %{"--accent" => hex(fill), "--accent-text" => hex(label)})

      :error ->
        vars
    end
  end

  def fix_accent_text(vars), do: vars

  @doc """
  Backfill `--selection-bg` / `--selection-text` onto an already-derived
  variant map (e.g. one persisted before these keys existed), using its own
  `--accent` / `--bg` rather than re-deriving from scratch.
  """
  def add_selection_vars(%{"--accent" => accent, "--bg" => bg} = vars) do
    {:ok, accent_rgb} = parse(accent)
    {:ok, bg_rgb} = parse(bg)
    selection_bg = ensure_contrast(accent_rgb, bg_rgb, 7.0)

    Map.merge(vars, %{
      "--selection-bg" => hex(selection_bg),
      "--selection-text" => hex(readable_on(selection_bg))
    })
  end

  @doc """
  Render a variant's var map into a CSS declaration body (no selector), e.g.
  `--bg: #…; --text: #…;`. Used to inject the dynamic `[data-theme="game"]` block.
  """
  def to_css(vars) when is_map(vars) do
    vars
    |> Enum.sort()
    |> Enum.map_join(" ", fn {k, v} -> "#{k}: #{v};" end)
  end

  # Long enough for "Longest Night" and friends; short enough that a runaway
  # generation can't blow out the picker's width.
  @max_name_length 24

  @doc """
  Pull the two player-facing variant names out of the raw model response.

  Returns `{:ok, %{"light" => name, "dark" => name}}` or `:error` when either is
  missing or unusable. Names are free text from the model, so they are trimmed,
  collapsed, length-capped and stripped of characters that have meaning in the
  markup they land in — a `<style>` tag's attribute and an `<option>` label.
  Callers treat `:error` as "no names", not as a palette failure: a game with a
  good palette and a bad name still gets its theme, under the generic label.
  """
  def names(%{"names" => %{"light" => light, "dark" => dark}}) do
    with {:ok, l} <- clean_name(light),
         {:ok, d} <- clean_name(dark) do
      {:ok, %{"light" => l, "dark" => d}}
    end
  end

  def names(_), do: :error

  defp clean_name(name) when is_binary(name) do
    cleaned =
      name
      |> String.replace(~r/[<>"'&\\\r\n\t]/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.slice(0, @max_name_length)
      |> String.trim()

    if cleaned == "", do: :error, else: {:ok, cleaned}
  end

  defp clean_name(_), do: :error
end
