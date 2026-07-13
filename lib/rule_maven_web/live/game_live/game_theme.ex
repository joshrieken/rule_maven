defmodule RuleMavenWeb.GameLive.GameTheme do
  @moduledoc """
  Shared rendering for the per-game themes + blurred cover background. Used by
  every game-scoped page (Q&A `Show`, `FAQ`, `Review`, `Prepare`, `Form` edit)
  so they all expose the game's generated theme sets and the cover-art backdrop —
  any new game-scoped LiveView should call both at the top of its `render/1`:

      {RuleMavenWeb.GameLive.GameTheme.style_block(@game)}
      <RuleMavenWeb.GameLive.GameTheme.blur_background image_url={@game.image_url} />
      <div style="position:relative;z-index:1">
        ...
      </div>

  The wrapping div needs `position:relative;z-index:1` so its content stacks
  above the fixed, `z-index:0` blur layer. `style_block/1` no-ops (renders
  nothing) for `nil` — safe on pages like `Form`'s `:new` action where there's
  no game yet.
  """
  use Phoenix.Component

  alias RuleMaven.{Games, Metrics, ThemePalette}

  @doc """
  Inline `[data-theme="…"]` variable blocks for every one of a game's theme
  sets (set 1 keeps the historical `game-light`/`game-dark` slugs; sets 2+ are
  `game-N-light`/`game-N-dark`), scoped via the `#game-theme` marker the picker
  script looks for. Only values we generated (hex/rgba) go into the CSS body —
  no user input — so raw/1 is safe there. Renders nothing until a palette
  exists.

  The full variant list rides along as a `data-variants` JSON attribute
  (`[{"value": slug, "name": label}, …]`, picker order) on the same marker; the
  picker script builds the game optgroup from it. Set 1's names also keep the
  legacy `data-light-name`/`data-dark-name` attributes. The names are
  model-authored free text, so both the JSON and the attributes are
  HTML-escaped here (on top of the character scrub in `ThemePalette.names/1`).

  Expansions don't generate their own palette; this resolves to the base
  game's palette instead (see `RuleMaven.Games.effective_theme_palette/1`).
  """
  def style_block(%RuleMaven.Games.Game{} = game) do
    case theme_sets(game) do
      [] ->
        Phoenix.HTML.raw("")

      [first | _] = sets ->
        css =
          Enum.map_join(sets, "", fn set ->
            ~s|[data-theme="#{set.light_slug}"]{#{ThemePalette.to_css(set.light)}}| <>
              ~s|[data-theme="#{set.dark_slug}"]{#{ThemePalette.to_css(set.dark)}}|
          end)

        variants_json =
          sets
          |> Enum.flat_map(fn set ->
            [
              %{value: set.light_slug, name: set.light_name},
              %{value: set.dark_slug, name: set.dark_name}
            ]
          end)
          |> Jason.encode!()

        Phoenix.HTML.raw(
          ~s(<style id="game-theme" data-light-name="#{escape(first.light_name)}" ) <>
            ~s(data-dark-name="#{escape(first.dark_name)}" ) <>
            ~s(data-variants="#{escape(variants_json)}">#{css}</style>)
        )
    end
  end

  def style_block(_), do: Phoenix.HTML.raw("")

  @doc """
  A game's renderable theme sets, picker order: a list of
  `%{light_slug, dark_slug, light, dark, light_name, dark_name}` maps. Handles
  both the stored sets shape and legacy single-set palettes, lifts old
  palettes to the current contrast floors at render time (no data backfill),
  and fills unusable names with the generic labels ("Game Light",
  "Game Light 2", …). Empty when the game has no usable palette.
  """
  def theme_sets(%RuleMaven.Games.Game{} = game) do
    palettes = ThemePalette.palette_sets(Games.effective_theme_palette(game) || %{})
    names = ThemePalette.name_sets(Games.effective_theme_names(game) || %{})
    defaults = Map.new(Metrics.game_themes())

    palettes
    |> Enum.with_index(1)
    |> Enum.map(fn {%{"light" => light, "dark" => dark}, n} ->
      set_names = Enum.at(names, n - 1) || %{}

      %{
        light_slug: Metrics.game_theme_slug(n, :light),
        dark_slug: Metrics.game_theme_slug(n, :dark),
        light: fixup(light),
        dark: fixup(dark),
        light_name: label(set_names["light"], default_label(defaults["game-light"], n)),
        dark_name: label(set_names["dark"], default_label(defaults["game-dark"], n))
      }
    end)
  end

  def theme_sets(_), do: []

  # Palettes persisted before the text-contrast floors were raised (or before
  # --accent-text escalated on mid-luminance accents) get lifted at render
  # time — no data backfill needed.
  defp fixup(vars) do
    vars
    |> ThemePalette.fix_text_contrast()
    |> ThemePalette.fix_accent_text()
  end

  defp default_label(base, 1), do: base
  defp default_label(base, n), do: "#{base} #{n}"

  @doc """
  The `{light_label, dark_label}` shown for this game's FIRST theme set — its
  generated names when it has them, otherwise the generic labels from
  `RuleMaven.Metrics.game_themes/0`. Falls back per-variant, so a set with
  only one usable name still shows that one.
  """
  def variant_labels(game) do
    names =
      case game do
        %RuleMaven.Games.Game{} ->
          Games.effective_theme_names(game)
          |> Kernel.||(%{})
          |> ThemePalette.name_sets()
          |> List.first()
          |> Kernel.||(%{})

        _ ->
          %{}
      end

    defaults = Map.new(Metrics.game_themes())

    {
      label(names["light"], defaults["game-light"]),
      label(names["dark"], defaults["game-dark"])
    }
  end

  defp label(name, default) when is_binary(name) do
    case String.trim(name) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp label(_, default), do: default

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  @doc """
  True when a game has at least one generated light+dark theme set, i.e. the
  game themes are offered for it. Mirrors the guard in `style_block/1`; use it
  to gate UI that nudges players toward the game themes.
  """
  def has_palette?(%RuleMaven.Games.Game{} = game) do
    ThemePalette.palette_sets(Games.effective_theme_palette(game) || %{}) != []
  end

  def has_palette?(_), do: false

  @doc """
  A faint, blurred cover-art backdrop fixed behind the page content. Blurs a
  quarter-size surface scaled 4× so the filter runs over ~1/16 the pixels.
  Renders nothing without a cover image.
  """
  attr :image_url, :string, default: nil

  def blur_background(assigns) do
    ~H"""
    <div
      :if={@image_url}
      class="blur-bg"
      aria-hidden="true"
      style={"position:fixed;top:0;left:0;width:25%;height:25%;z-index:0;transform-origin:top left;transform:scale(4);background-image:url('#{@image_url}');background-size:cover;background-position:center;filter:blur(5px) saturate(1.15);opacity:0.22;pointer-events:none"}
    >
    </div>
    """
  end
end
