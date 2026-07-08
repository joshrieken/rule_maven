defmodule RuleMaven.ThemePaletteTest do
  use ExUnit.Case, async: true

  alias RuleMaven.ThemePalette

  # Anchors like the dark-maroon cover that surfaced the bug: dim warm text on
  # a near-black red background.
  @dark_anchors %{
    "accent" => "#8A2020",
    "bg" => "#201010",
    "surface" => "#2A1614",
    "text" => "#C0A090"
  }
  @light_anchors %{
    "accent" => "#8A2020",
    "bg" => "#F6EEE8",
    "surface" => "#FFFFFF",
    "text" => "#302020"
  }

  defp contrast(hex_a, hex_b) do
    {:ok, a} = ThemePalette.parse(hex_a)
    {:ok, b} = ThemePalette.parse(hex_b)
    {la, lb} = {luminance(a), luminance(b)}
    {hi, lo} = if la >= lb, do: {la, lb}, else: {lb, la}
    (hi + 0.05) / (lo + 0.05)
  end

  defp luminance({r, g, b}) do
    [r, g, b]
    |> Enum.map(fn c ->
      c = c / 255
      if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
    end)
    |> then(fn [r, g, b] -> 0.2126 * r + 0.7152 * g + 0.0722 * b end)
  end

  defp assert_floors(vars) do
    for bg_key <- ["--bg", "--bg-surface", "--bg-subtle"] do
      assert contrast(vars["--text-secondary"], vars[bg_key]) >= 6.0,
             "--text-secondary vs #{bg_key} below 6.0"

      assert contrast(vars["--text-muted"], vars[bg_key]) >= 4.5,
             "--text-muted vs #{bg_key} below 4.5"
    end
  end

  test "derived palettes clear the text contrast floors on every background" do
    {:ok, %{"light" => light, "dark" => dark}} =
      ThemePalette.build(%{"light" => @light_anchors, "dark" => @dark_anchors})

    assert_floors(light)
    assert_floors(dark)
  end

  test "fix_text_contrast lifts a dim legacy palette" do
    # Values a pre-fix palette could persist: muted only had a 3.0 floor and
    # was only checked against --bg-surface.
    legacy = %{
      "--bg" => "#201010",
      "--bg-surface" => "#2A1614",
      "--bg-subtle" => "#2A1211",
      "--text" => "#E8D8CC",
      "--text-secondary" => "#907868",
      "--text-muted" => "#6A5448"
    }

    fixed = ThemePalette.fix_text_contrast(legacy)
    assert_floors(fixed)
    # Untouched keys pass through.
    assert fixed["--text"] == legacy["--text"]
  end

  test "fix_text_contrast is idempotent on freshly derived palettes" do
    {:ok, %{"dark" => dark}} =
      ThemePalette.build(%{"light" => @light_anchors, "dark" => @dark_anchors})

    assert ThemePalette.fix_text_contrast(dark) == dark
  end

  test "fix_text_contrast passes malformed maps through unchanged" do
    assert ThemePalette.fix_text_contrast(%{}) == %{}

    partial = %{"--bg" => "#201010", "--bg-surface" => "not-a-color"}
    assert ThemePalette.fix_text_contrast(partial) == partial
  end

  # Mid-luminance accent (the Ethnos gold): near-black #1A1A1A only reaches
  # ~4.7:1 and white ~3.7:1 — button labels read muddy. The text color must
  # escalate to a pure extreme when the soft near-black can't clear 6:1.
  @mid_gold "#9E823B"

  test "accent-text on a mid-luminance accent clears 5.5:1" do
    {:ok, %{"dark" => dark}} =
      ThemePalette.build(%{
        "light" => @light_anchors,
        "dark" => Map.put(@dark_anchors, "accent", @mid_gold)
      })

    assert contrast(dark["--accent-text"], dark["--accent"]) >= 5.5
  end

  test "accent-text keeps the soft near-black on bright accents" do
    {:ok, %{"dark" => dark}} =
      ThemePalette.build(%{
        "light" => @light_anchors,
        "dark" => Map.put(@dark_anchors, "accent", "#E8C552")
      })

    assert dark["--accent-text"] == "#1A1A1A"
  end

  test "fix_accent_text lifts a legacy palette with a muddy accent-text" do
    legacy = %{"--accent" => @mid_gold, "--accent-text" => "#1A1A1A"}
    fixed = ThemePalette.fix_accent_text(legacy)
    assert contrast(fixed["--accent-text"], @mid_gold) >= 5.5
  end

  test "fix_accent_text adds accent-text to palettes persisted before the key existed" do
    fixed = ThemePalette.fix_accent_text(%{"--accent" => @mid_gold})
    assert contrast(fixed["--accent-text"], @mid_gold) >= 5.5
  end

  test "fix_accent_text is idempotent on freshly derived palettes" do
    {:ok, %{"dark" => dark}} =
      ThemePalette.build(%{"light" => @light_anchors, "dark" => @dark_anchors})

    assert ThemePalette.fix_accent_text(dark) == dark
  end

  test "fix_accent_text passes malformed maps through unchanged" do
    assert ThemePalette.fix_accent_text(%{}) == %{}
    bad = %{"--accent" => "not-a-color", "--accent-text" => "#1A1A1A"}
    assert ThemePalette.fix_accent_text(bad) == bad
  end
end
