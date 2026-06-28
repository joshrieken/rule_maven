defmodule RuleMaven.Metrics do
  @moduledoc """
  Usage metrics. Currently tracks theme selections so we can see which themes
  people actually pick.
  """

  import Ecto.Query
  alias RuleMaven.Repo
  alias RuleMaven.Metrics.ThemeEvent

  # Slug -> human label, in the order shown in the theme picker. The slug is the
  # `data-theme` value AND the kebab-case of the label — one canonical name per
  # theme, no drift. This list is the single source of truth: the picker, the
  # CSS `[data-theme="…"]` blocks, and the allowlist all derive from it.
  @themes [
    {"abyss", "Abyss"},
    {"arcade", "Arcade"},
    {"brass", "Brass"},
    {"canopy", "Canopy"},
    {"cassette", "Cassette"},
    {"coral", "Coral"},
    {"crypt", "Crypt"},
    {"dusk", "Dusk"},
    {"ember", "Ember"},
    {"frost", "Frost"},
    {"golden-hour", "Golden Hour"},
    {"honey", "Honey"},
    {"lavender", "Lavender"},
    {"marble", "Marble"},
    {"meadow", "Meadow"},
    {"midnight", "Midnight"},
    {"nebula", "Nebula"},
    {"neon", "Neon"},
    {"parchment", "Parchment"},
    {"twilight", "Twilight"},
    {"void", "Void"}
  ]

  # The dynamic per-game theme. Not a static `[data-theme]` block in app.css —
  # its variables are injected inline on a game page from `games.theme_palette`.
  # Kept out of `@themes` (which drives the global picker + CSS blocks) but valid
  # for selection logging. See RuleMaven.ThemePalette / ThemePaletteWorker.
  @game_theme {"game", "Game-Specific"}

  @doc "The `{slug, label}` for the dynamic per-game theme."
  def game_theme, do: @game_theme

  @doc "Default theme slug for users who prefer light / dark color schemes."
  def default_theme(:dark), do: "midnight"
  def default_theme(_), do: "lavender"

  @doc "Ordered list of `{slug, label}` for every selectable theme."
  def themes, do: @themes

  @doc "Allowlist of valid theme slugs (includes the dynamic `game` theme)."
  def theme_slugs, do: [elem(@game_theme, 0) | Enum.map(@themes, &elem(&1, 0))]

  @doc "Map of slug => label."
  def theme_labels, do: Map.new(@themes)

  @doc """
  Records that `theme` was selected. `user_id` may be nil for logged-out
  visitors. Invalid (non-allowlisted) themes are dropped, returning `:error`.
  """
  def record_theme(theme, user_id \\ nil) do
    %ThemeEvent{}
    |> ThemeEvent.changeset(%{theme: theme, user_id: user_id})
    |> Repo.insert()
    |> case do
      {:ok, event} -> {:ok, event}
      {:error, _changeset} -> :error
    end
  end

  @doc """
  Selection counts per theme as a map of `slug => count`. Themes that have
  never been picked are omitted; callers can fall back to `theme_labels/0`.
  """
  def theme_counts do
    ThemeEvent
    |> group_by([e], e.theme)
    |> select([e], {e.theme, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Total number of recorded theme selections."
  def total_theme_events do
    Repo.aggregate(ThemeEvent, :count, :id)
  end
end
