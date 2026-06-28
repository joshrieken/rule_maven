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

  defp derive(accent, bg, surface, text, scheme) do
    # On dark schemes "toward background" means lighter borders / muted text;
    # the math is the same (mix text into bg) because text already contrasts bg.
    text = ensure_contrast(text, bg, 7.0)
    on_surface = ensure_contrast(text, surface, 7.0)

    shadow =
      case scheme do
        :light -> "rgba(0, 0, 0, 0.06)"
        :dark -> "rgba(0, 0, 0, 0.40)"
      end

    %{
      "--bg" => hex(bg),
      "--bg-surface" => hex(surface),
      "--bg-subtle" => hex(mix(bg, accent, 0.08)),
      "--bg-danger" => @semantic[scheme_key(scheme)]["--red-bg"],
      "--text" => hex(on_surface),
      "--text-heading" => hex(ensure_contrast(darken_toward_text(text, scheme), surface, 7.0)),
      "--text-secondary" => hex(ensure_contrast(mix(text, bg, 0.40), surface, 4.5)),
      "--text-muted" => hex(ensure_contrast(mix(text, bg, 0.58), surface, 3.0)),
      "--border" => hex(mix(text, bg, 0.78)),
      "--border-strong" => hex(mix(text, bg, 0.62)),
      "--border-subtle" => hex(mix(text, bg, 0.88)),
      "--accent" => hex(accent),
      "--accent-dark" => hex(darken(accent, 0.18)),
      "--accent-light" => hex(lighten(accent, 0.20)),
      "--accent-subtle" => hex(mix(bg, accent, 0.12)),
      "--shadow" => shadow,
      "--shadow-hover" => rgba(accent, 0.18),
      "--header-bg-start" => hex(darken(accent, 0.15)),
      "--header-bg-end" => hex(darken(accent, 0.38)),
      "--header-border" => @semantic[scheme_key(scheme)]["--yellow"],
      "--focus-ring" => rgba(accent, 0.18)
    }
    |> Map.merge(@semantic[scheme_key(scheme)])
  end

  defp scheme_key(:light), do: "light"
  defp scheme_key(:dark), do: "dark"

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
    "#" <> (Enum.map_join([r, g, b], &(&1 |> clamp() |> Integer.to_string(16) |> String.pad_leading(2, "0"))) |> String.upcase())
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
  Render a variant's var map into a CSS declaration body (no selector), e.g.
  `--bg: #…; --text: #…;`. Used to inject the dynamic `[data-theme="game"]` block.
  """
  def to_css(vars) when is_map(vars) do
    vars
    |> Enum.sort()
    |> Enum.map_join(" ", fn {k, v} -> "#{k}: #{v};" end)
  end
end
