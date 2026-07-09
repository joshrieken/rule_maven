defmodule RuleMavenWeb.GameLive.GameTheme do
  @moduledoc """
  Shared rendering for the per-game theme + blurred cover background. Used by
  every game-scoped page (Q&A `Show`, `FAQ`, `Review`, `Prepare`, `Form` edit)
  so they all expose the Game Light / Dark themes and the cover-art backdrop —
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

  @doc """
  Inline `[data-theme="game-light"]` / `[data-theme="game-dark"]` variable blocks
  for a game, scoped via the `#game-theme` marker the picker script looks for.
  Only values we generated (hex/rgba) go into the CSS body — no user input — so
  raw/1 is safe there. Renders nothing until a palette exists.

  The variant names ride along as `data-light-name` / `data-dark-name` on the
  same marker; the picker script reads them to label the game options. Unlike
  the colours these are model-authored free text, so they are HTML-escaped here
  (on top of the character scrub in `ThemePalette.names/1`).

  Expansions don't generate their own palette; this resolves to the base
  game's palette instead (see `RuleMaven.Games.effective_theme_palette/1`).
  """
  def style_block(%RuleMaven.Games.Game{} = game) do
    case RuleMaven.Games.effective_theme_palette(game) do
      %{"light" => light, "dark" => dark} when is_map(light) and is_map(dark) ->
        # Palettes persisted before the text-contrast floors were raised (or
        # before --accent-text escalated on mid-luminance accents) get lifted
        # here at render time — no data backfill needed.
        light =
          light
          |> RuleMaven.ThemePalette.fix_text_contrast()
          |> RuleMaven.ThemePalette.fix_accent_text()

        dark =
          dark
          |> RuleMaven.ThemePalette.fix_text_contrast()
          |> RuleMaven.ThemePalette.fix_accent_text()

        css =
          ~s|[data-theme="game-light"]{#{RuleMaven.ThemePalette.to_css(light)}}| <>
            ~s|[data-theme="game-dark"]{#{RuleMaven.ThemePalette.to_css(dark)}}|

        {light_name, dark_name} = variant_labels(game)

        Phoenix.HTML.raw(
          ~s(<style id="game-theme" data-light-name="#{escape(light_name)}" ) <>
            ~s(data-dark-name="#{escape(dark_name)}">#{css}</style>)
        )

      _ ->
        Phoenix.HTML.raw("")
    end
  end

  def style_block(_), do: Phoenix.HTML.raw("")

  @doc """
  The `{light_label, dark_label}` shown for this game's two theme variants —
  its generated names when it has them, otherwise the generic labels from
  `RuleMaven.Metrics.game_themes/0`. Falls back per-variant, so a palette with
  only one usable name still shows that one.
  """
  def variant_labels(game) do
    names =
      case game do
        %RuleMaven.Games.Game{} -> RuleMaven.Games.effective_theme_names(game) || %{}
        _ -> %{}
      end

    defaults = Map.new(RuleMaven.Metrics.game_themes())

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
  True when a game has a generated light+dark palette, i.e. the Game Light /
  Game Dark themes are offered for it. Mirrors the guard in `style_block/1`;
  use it to gate UI that nudges players toward the game themes.
  """
  def has_palette?(%RuleMaven.Games.Game{} = game) do
    case RuleMaven.Games.effective_theme_palette(game) do
      %{"light" => light, "dark" => dark} when is_map(light) and is_map(dark) -> true
      _ -> false
    end
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
