defmodule RuleMavenWeb.GameThemeVariantLabelsTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.Games
  alias RuleMavenWeb.GameLive.GameTheme

  @palette %{
    "light" => %{"--bg" => "#FFFFFF", "--text" => "#111111"},
    "dark" => %{"--bg" => "#111111", "--text" => "#FFFFFF"}
  }

  defp render_marker(game) do
    game |> GameTheme.style_block() |> Phoenix.HTML.safe_to_string()
  end

  describe "variant_labels/1" do
    test "uses the game's generated names" do
      {:ok, game} = Games.create_game(%{name: "VL Named"})

      {:ok, game} =
        Games.update_game(game, %{
          theme_palette: @palette,
          theme_names: %{"light" => "Harbor Daylight", "dark" => "Longest Night"}
        })

      assert {"Harbor Daylight", "Longest Night"} = GameTheme.variant_labels(game)
    end

    test "falls back to the generic labels when the palette predates names" do
      {:ok, game} = Games.create_game(%{name: "VL Unnamed"})
      {:ok, game} = Games.update_game(game, %{theme_palette: @palette})

      assert {"Game Light", "Game Dark"} = GameTheme.variant_labels(game)
    end

    test "falls back per-variant when only one name is usable" do
      {:ok, game} = Games.create_game(%{name: "VL Half"})

      {:ok, game} =
        Games.update_game(game, %{
          theme_palette: @palette,
          theme_names: %{"light" => "Harbor Daylight", "dark" => "  "}
        })

      assert {"Harbor Daylight", "Game Dark"} = GameTheme.variant_labels(game)
    end

    test "an expansion inherits its base game's names, like it inherits the palette" do
      {:ok, base} = Games.create_game(%{name: "VL Base"})
      {:ok, exp} = Games.create_game(%{name: "VL Exp"})
      :ok = Games.link_expansion(exp.id, base.id)

      {:ok, _} =
        Games.update_game(base, %{
          theme_palette: @palette,
          theme_names: %{"light" => "Harbor Daylight", "dark" => "Longest Night"}
        })

      exp = Games.get_game!(exp.id)
      assert {"Harbor Daylight", "Longest Night"} = GameTheme.variant_labels(exp)
    end
  end

  describe "style_block/1" do
    test "publishes the names on the #game-theme marker for the picker script" do
      {:ok, game} = Games.create_game(%{name: "VL Marker"})

      {:ok, game} =
        Games.update_game(game, %{
          theme_palette: @palette,
          theme_names: %{"light" => "Harbor Daylight", "dark" => "Longest Night"}
        })

      html = render_marker(game)

      assert html =~ ~s(data-light-name="Harbor Daylight")
      assert html =~ ~s(data-dark-name="Longest Night")
    end

    test "escapes a name that would otherwise break out of the attribute" do
      {:ok, game} = Games.create_game(%{name: "VL Inject"})

      # A name that skipped ThemePalette.names/1 (e.g. written straight to the
      # column) must still not be able to close the attribute or the tag.
      {:ok, game} =
        Games.update_game(game, %{
          theme_palette: @palette,
          theme_names: %{"light" => ~s(a" onload="x), "dark" => "b</style><script>"}
        })

      html = render_marker(game)

      refute html =~ ~s(onload="x")
      refute html =~ "<script>"
      assert html =~ "&quot;"
      assert String.starts_with?(html, "<style id=\"game-theme\"")
    end

    test "renders nothing without a palette, names or not" do
      {:ok, game} = Games.create_game(%{name: "VL No Palette"})
      {:ok, game} = Games.update_game(game, %{theme_names: %{"light" => "X", "dark" => "Y"}})

      assert render_marker(game) == ""
    end
  end

  describe "style_block/1 with multiple theme sets" do
    @palette2 %{
      "light" => %{"--bg" => "#F0F8FF", "--text" => "#102030"},
      "dark" => %{"--bg" => "#102030", "--text" => "#F0F8FF"}
    }

    defp multi_set_game(names) do
      {:ok, game} = Games.create_game(%{name: "VL Multi #{System.unique_integer([:positive])}"})

      {:ok, game} =
        Games.update_game(game, %{
          theme_palette: %{"sets" => [@palette, @palette2]},
          theme_names: names
        })

      game
    end

    test "emits one CSS block per variant per set, set 1 on the legacy slugs" do
      game =
        multi_set_game(%{
          "sets" => [
            %{"light" => "Harbor Daylight", "dark" => "Longest Night"},
            %{"light" => "Tide Morning", "dark" => "Deep Current"}
          ]
        })

      html = render_marker(game)

      assert html =~ ~s([data-theme="game-light"])
      assert html =~ ~s([data-theme="game-dark"])
      assert html =~ ~s([data-theme="game-2-light"])
      assert html =~ ~s([data-theme="game-2-dark"])
      refute html =~ ~s([data-theme="game-3-light"])
    end

    test "publishes the full variant list as data-variants JSON, picker order" do
      game =
        multi_set_game(%{
          "sets" => [
            %{"light" => "Harbor Daylight", "dark" => "Longest Night"},
            %{"light" => "Tide Morning", "dark" => "Deep Current"}
          ]
        })

      html = render_marker(game)

      [_, encoded] = Regex.run(~r/data-variants="([^"]*)"/, html)

      variants =
        encoded
        |> String.replace("&quot;", "\"")
        |> String.replace("&amp;", "&")
        |> Jason.decode!()

      assert variants == [
               %{"value" => "game-light", "name" => "Harbor Daylight"},
               %{"value" => "game-dark", "name" => "Longest Night"},
               %{"value" => "game-2-light", "name" => "Tide Morning"},
               %{"value" => "game-2-dark", "name" => "Deep Current"}
             ]

      # Set 1's names still ride the legacy attributes for old markers' sake.
      assert html =~ ~s(data-light-name="Harbor Daylight")
      assert html =~ ~s(data-dark-name="Longest Night")
    end

    test "a set without usable names falls back to numbered generic labels" do
      game =
        multi_set_game(%{
          "sets" => [%{"light" => "Harbor Daylight", "dark" => "Longest Night"}, nil]
        })

      html = render_marker(game)

      assert html =~ "Game Light 2"
      assert html =~ "Game Dark 2"
    end

    test "legacy single-set rows render exactly one set on the legacy slugs" do
      {:ok, game} = Games.create_game(%{name: "VL Legacy"})

      {:ok, game} =
        Games.update_game(game, %{
          theme_palette: @palette,
          theme_names: %{"light" => "Harbor Daylight", "dark" => "Longest Night"}
        })

      html = render_marker(game)

      assert html =~ ~s([data-theme="game-light"])
      refute html =~ "game-2-light"
      assert html =~ ~s(data-light-name="Harbor Daylight")
    end

    test "theme_sets/1 slugs stay inside the Metrics allowlist" do
      game =
        multi_set_game(%{
          "sets" => [
            %{"light" => "Harbor Daylight", "dark" => "Longest Night"},
            %{"light" => "Tide Morning", "dark" => "Deep Current"}
          ]
        })

      slugs =
        game
        |> GameTheme.theme_sets()
        |> Enum.flat_map(&[&1.light_slug, &1.dark_slug])

      assert Enum.all?(slugs, &(&1 in RuleMaven.Metrics.theme_slugs()))
    end
  end
end
