defmodule RuleMavenWeb.StaticThemeAccentTextTest do
  @moduledoc """
  Pins accent-fill legibility for the hand-authored themes in app.css.

  Buttons render `background: var(--accent); color: var(--accent-text, #fff)`.
  Only `:root` used to define `--accent-text` (white), so every theme whose
  accent is mid-luminance (golds, corals, teals…) shipped ~2.5–3.9:1 button
  labels. Each theme block must now carry an `--accent-text` that clears
  WCAG AA (4.5:1) against its own accent — including the Midnight system
  fallback block inside the `prefers-color-scheme: dark` media query.
  """

  use ExUnit.Case, async: true

  @css_path Path.join(File.cwd!(), "priv/static/assets/css/app.css")

  defp luminance({r, g, b}) do
    [r, g, b]
    |> Enum.map(fn c ->
      c = c / 255
      if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
    end)
    |> then(fn [r, g, b] -> 0.2126 * r + 0.7152 * g + 0.0722 * b end)
  end

  defp contrast(hex_a, hex_b) do
    {:ok, a} = RuleMaven.ThemePalette.parse(hex_a)
    {:ok, b} = RuleMaven.ThemePalette.parse(hex_b)
    {la, lb} = {luminance(a), luminance(b)}
    (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  end

  # Every `selector { ... }` block that declares an --accent, keyed by a label
  # (theme name, ":root", or "system-dark-fallback").
  defp theme_blocks do
    css = File.read!(@css_path)

    Regex.scan(~r/([^{}]+)\{([^{}]*--accent:[^{}]*)\}/, css)
    |> Enum.map(fn [_, selector, body] ->
      label =
        case Regex.run(~r/data-theme="([^"]+)"/, selector) do
          [_, name] -> name
          nil -> if selector =~ ":root:not", do: "system-dark-fallback", else: ":root"
        end

      {label, body}
    end)
  end

  defp var(body, name) do
    case Regex.run(~r/#{name}:\s*(#[0-9A-Fa-f]{3,6})/, body) do
      [_, hex] -> hex
      nil -> nil
    end
  end

  test "every theme's --accent-text clears 4.5:1 against its --accent" do
    blocks = theme_blocks()
    assert length(blocks) > 20, "expected to find the theme blocks in app.css"

    for {label, body} <- blocks do
      accent = var(body, "--accent")
      # Missing --accent-text means the :root white fallback applies.
      accent_text = var(body, "--accent-text") || "#FFFFFF"

      assert contrast(accent, accent_text) >= 4.5,
             "theme #{label}: --accent-text #{accent_text} on --accent #{accent} " <>
               "is #{Float.round(contrast(accent, accent_text), 2)}:1 (< 4.5)"
    end
  end

  # Same floors the generated palettes enforce (ThemePalette @secondary_ratio /
  # @muted_ratio), applied to the hand-authored themes: every text tier must
  # read on every background it can land on. Muted text is used for real
  # content (timestamps, helper copy, disabled button labels), so it gets the
  # full WCAG AA floor, not a decorative pass.
  @text_floors [
    {"--text", 7.0},
    {"--text-secondary", 4.5},
    {"--text-muted", 4.5}
  ]
  @backgrounds ["--bg", "--bg-surface", "--bg-subtle"]

  test "every theme's text tiers clear their floors on every background" do
    for {label, body} <- theme_blocks(),
        {text_var, floor} <- @text_floors,
        bg_var <- @backgrounds do
      text = var(body, text_var)
      bg = var(body, bg_var)

      if text && bg do
        assert contrast(text, bg) >= floor,
               "theme #{label}: #{text_var} #{text} on #{bg_var} #{bg} " <>
                 "is #{Float.round(contrast(text, bg), 2)}:1 (< #{floor})"
      end
    end
  end
end
