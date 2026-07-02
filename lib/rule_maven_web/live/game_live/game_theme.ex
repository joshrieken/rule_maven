defmodule RuleMavenWeb.GameLive.GameTheme do
  @moduledoc """
  Shared rendering for the per-game theme + blurred cover background, used by the
  Q&A (`Show`) and `FAQ` pages so both expose the Game Light / Dark themes and
  the cover-art backdrop.
  """
  use Phoenix.Component

  @doc """
  Inline `[data-theme="game-light"]` / `[data-theme="game-dark"]` variable blocks
  for a game, scoped via the `#game-theme` marker the picker script looks for.
  Only values we generated (hex/rgba) are interpolated — no user input — so
  raw/1 is safe. Renders nothing until a palette exists.
  """
  def style_block(%{theme_palette: %{"light" => light, "dark" => dark}})
      when is_map(light) and is_map(dark) do
    css =
      ~s|[data-theme="game-light"]{#{RuleMaven.ThemePalette.to_css(light)}}| <>
        ~s|[data-theme="game-dark"]{#{RuleMaven.ThemePalette.to_css(dark)}}|

    Phoenix.HTML.raw(~s(<style id="game-theme">#{css}</style>))
  end

  def style_block(_), do: Phoenix.HTML.raw("")

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
