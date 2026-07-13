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
  # ~4.7:1 and white ~3.7:1, and even pure black tops out at ~5.8:1 — muddy
  # either way. Text alone can't fix a mid-tone fill, so the accent itself
  # must be lifted (toward the extreme opposite the text) until the button
  # label clears 7:1.
  @mid_gold "#9E823B"

  test "mid-luminance accents are lifted until the label clears 7:1" do
    {:ok, %{"dark" => dark}} =
      ThemePalette.build(%{
        "light" => @light_anchors,
        "dark" => Map.put(@dark_anchors, "accent", @mid_gold)
      })

    assert contrast(dark["--accent-text"], dark["--accent"]) >= 7.0
    # The lift brightens the gold, it must not swap it for white/grey: the
    # accent keeps a warm hue (red channel stays ahead of blue).
    {:ok, {r, _g, b}} = ThemePalette.parse(dark["--accent"])
    assert r > b
  end

  test "high-contrast accents pass through the fill lift unchanged" do
    {:ok, %{"dark" => dark}} =
      ThemePalette.build(%{"light" => @light_anchors, "dark" => @dark_anchors})

    # #8A2020 already clears 7:1 under white text — no lift.
    assert dark["--accent"] == "#8A2020"
  end

  test "accent-text keeps the soft near-black on bright accents" do
    {:ok, %{"dark" => dark}} =
      ThemePalette.build(%{
        "light" => @light_anchors,
        "dark" => Map.put(@dark_anchors, "accent", "#E8C552")
      })

    assert dark["--accent-text"] == "#1A1A1A"
  end

  test "fix_accent_text lifts a legacy palette with a muddy accent fill" do
    legacy = %{"--accent" => @mid_gold, "--accent-text" => "#1A1A1A"}
    fixed = ThemePalette.fix_accent_text(legacy)
    assert contrast(fixed["--accent-text"], fixed["--accent"]) >= 7.0
  end

  test "fix_accent_text adds accent-text to palettes persisted before the key existed" do
    fixed = ThemePalette.fix_accent_text(%{"--accent" => @mid_gold})
    assert contrast(fixed["--accent-text"], fixed["--accent"]) >= 7.0
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

  describe "build_sets/1" do
    @teal_anchors_light %{
      "accent" => "#20707A",
      "bg" => "#EAF4F4",
      "surface" => "#FFFFFF",
      "text" => "#203030"
    }
    @teal_anchors_dark %{
      "accent" => "#38B0BE",
      "bg" => "#101E20",
      "surface" => "#16282A",
      "text" => "#C8DCDC"
    }

    defp maroon_set(names \\ %{"light" => "Harbor Daylight", "dark" => "Longest Night"}) do
      %{"light" => @light_anchors, "dark" => @dark_anchors, "names" => names}
    end

    defp teal_set do
      %{
        "light" => @teal_anchors_light,
        "dark" => @teal_anchors_dark,
        "names" => %{"light" => "Tide Morning", "dark" => "Deep Current"}
      }
    end

    test "builds every set with its own names, order preserved" do
      assert {:ok, [first, second]} =
               ThemePalette.build_sets(%{"sets" => [maroon_set(), teal_set()]})

      assert first.names == %{"light" => "Harbor Daylight", "dark" => "Longest Night"}
      assert second.names == %{"light" => "Tide Morning", "dark" => "Deep Current"}
      assert first.palette["light"]["--accent"] != second.palette["light"]["--accent"]
      assert_floors(first.palette["dark"])
      assert_floors(second.palette["dark"])
    end

    test "drops malformed sets without failing the good ones" do
      broken = %{"light" => %{"accent" => "nope"}, "dark" => @dark_anchors}

      assert {:ok, [only]} =
               ThemePalette.build_sets(%{"sets" => [broken, maroon_set(), "junk"]})

      assert only.names["light"] == "Harbor Daylight"
    end

    test "unusable names never fail a set — the entry is just nil" do
      assert {:ok, [set]} = ThemePalette.build_sets(%{"sets" => [maroon_set(%{"light" => "X"})]})
      assert set.names == nil
    end

    test "collapses near-duplicate sets onto the earlier one" do
      near_dup = %{
        "light" => Map.put(@light_anchors, "accent", "#8B2222"),
        "dark" => Map.put(@dark_anchors, "accent", "#892121"),
        "names" => %{"light" => "Copy Day", "dark" => "Copy Night"}
      }

      assert {:ok, [only]} = ThemePalette.build_sets(%{"sets" => [maroon_set(), near_dup]})
      assert only.names["light"] == "Harbor Daylight"
    end

    test "caps at 5 sets" do
      # 6 clearly distinct accent/bg pairings.
      sets =
        for {accent, tint} <- [
              {"#8A2020", "#F6EEE8"},
              {"#20707A", "#EAF4F4"},
              {"#6A4FA0", "#F0ECF8"},
              {"#2A8040", "#EAF6EC"},
              {"#B06010", "#FAF2E6"},
              {"#3060C0", "#EAF0FA"}
            ] do
          %{
            "light" => %{@light_anchors | "accent" => accent, "bg" => tint},
            "dark" => Map.put(@dark_anchors, "accent", accent)
          }
        end

      assert {:ok, built} = ThemePalette.build_sets(%{"sets" => sets})
      assert length(built) == 5
    end

    test "a bare legacy light/dark answer counts as one set" do
      assert {:ok, [set]} = ThemePalette.build_sets(maroon_set())
      assert set.names["dark"] == "Longest Night"
    end

    test "errors when no set survives" do
      assert {:error, :no_usable_sets} = ThemePalette.build_sets(%{"sets" => ["junk", %{}]})
      assert {:error, :missing_variants} = ThemePalette.build_sets(%{"nope" => true})
    end
  end

  describe "palette_sets/1 and name_sets/1" do
    test "normalize the sets shape, dropping sets missing a variant" do
      good = %{"light" => %{"--bg" => "#FFF"}, "dark" => %{"--bg" => "#111"}}
      stored = %{"sets" => [good, %{"light" => %{}}, "junk"]}

      assert ThemePalette.palette_sets(stored) == [good]
    end

    test "wrap a legacy single-set palette and pass junk as empty" do
      legacy = %{"light" => %{"--bg" => "#FFF"}, "dark" => %{"--bg" => "#111"}}
      assert ThemePalette.palette_sets(legacy) == [legacy]
      assert ThemePalette.palette_sets(nil) == []
      assert ThemePalette.palette_sets(%{}) == []
    end

    test "name_sets keeps nil placeholders so indexes stay aligned" do
      assert ThemePalette.name_sets(%{"sets" => [nil, %{"light" => "A", "dark" => "B"}]}) ==
               [nil, %{"light" => "A", "dark" => "B"}]

      legacy = %{"light" => "A", "dark" => "B"}
      assert ThemePalette.name_sets(legacy) == [legacy]
      assert ThemePalette.name_sets(nil) == []
    end
  end

  describe "names/1" do
    test "extracts and trims both variant names" do
      raw = %{"names" => %{"light" => "  Harbor Daylight ", "dark" => "Longest Night"}}

      assert {:ok, %{"light" => "Harbor Daylight", "dark" => "Longest Night"}} =
               ThemePalette.names(raw)
    end

    test "is :error when names are missing, partial, blank or not strings" do
      assert :error = ThemePalette.names(%{})
      assert :error = ThemePalette.names(%{"names" => %{"light" => "Day"}})
      assert :error = ThemePalette.names(%{"names" => %{"light" => "Day", "dark" => "   "}})
      assert :error = ThemePalette.names(%{"names" => %{"light" => "Day", "dark" => 42}})
    end

    test "scrubs characters that would break out of the markup it lands in" do
      raw = %{
        "names" => %{
          "light" => ~s|Day" onload="alert(1)|,
          "dark" => "Night<script>&"
        }
      }

      {:ok, %{"light" => light, "dark" => dark}} = ThemePalette.names(raw)

      for name <- [light, dark], char <- ~w(< > " &) do
        refute String.contains?(name, char), "#{inspect(name)} still contains #{char}"
      end
    end

    test "keeps apostrophes — every sink escapes them" do
      raw = %{"names" => %{"light" => "Dragon's Dawn", "dark" => "Dragon's Lair"}}

      assert {:ok, %{"light" => "Dragon's Dawn", "dark" => "Dragon's Lair"}} =
               ThemePalette.names(raw)
    end

    test "collapses whitespace and caps the length so the picker can't blow out" do
      raw = %{
        "names" => %{
          "light" => "Harbor\n\tDaylight",
          "dark" => String.duplicate("Night ", 40)
        }
      }

      {:ok, %{"light" => light, "dark" => dark}} = ThemePalette.names(raw)

      assert light == "Harbor Daylight"
      assert String.length(dark) <= 18
      # capped mid-word, but never left with a trailing space
      assert dark == String.trim(dark)
    end
  end
end
