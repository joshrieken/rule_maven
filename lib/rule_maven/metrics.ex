defmodule RuleMaven.Metrics do
  @moduledoc """
  Usage metrics. Currently tracks theme selections so we can see which themes
  people actually pick.
  """

  import Ecto.Query
  alias RuleMaven.Repo
  alias RuleMaven.Metrics.ThemeEvent

  # Slug -> human label, alphabetical by label — the order shown in the theme
  # picker, which has no meaningful grouping to preserve. The slug is the
  # `data-theme` value AND the kebab-case of the label — one canonical name per
  # theme, no drift. This list is the single source of truth: the picker, the
  # CSS `[data-theme="…"]` blocks, and the allowlist all derive from it.
  @themes [
    {"black-hole", "Black Hole"},
    {"campfire", "Campfire"},
    {"cheat-code", "Cheat Code"},
    {"chess-club", "Chess Club"},
    {"deep-space", "Deep Space"},
    {"dungeon-master", "Dungeon Master"},
    {"flamingo", "Flamingo"},
    {"fresh-deck", "Fresh Deck"},
    {"grave-digger", "Grave Digger"},
    {"honeycomb", "Honeycomb"},
    {"insert-coin", "Insert Coin"},
    {"kraken", "Kraken"},
    {"last-turn", "Last Turn"},
    {"lemonade", "Lemonade"},
    {"mixtape", "Mixtape"},
    {"moonrise", "Moonrise"},
    {"night-owl", "Night Owl"},
    {"overgrowth", "Overgrowth"},
    {"picnic", "Picnic"},
    {"snow-day", "Snow Day"},
    {"steamworks", "Steamworks"}
  ]

  # The dynamic per-game themes. Not static `[data-theme]` blocks in app.css —
  # their variables are injected inline on a game page from `games.theme_palette`.
  # Two explicit variants (light/dark) so the user picks one directly, like every
  # other theme, instead of relying on the OS color-scheme. Kept out of `@themes`
  # (which drives the static picker + CSS blocks) but valid for selection logging.
  # See RuleMaven.ThemePalette / ThemePaletteWorker.
  @game_themes [
    {"game-light", "Game Light"},
    {"game-dark", "Game Dark"}
  ]

  @doc "Ordered `{slug, label}` list for the dynamic per-game themes."
  def game_themes, do: @game_themes

  @doc "Default theme slug for users who prefer light / dark color schemes."
  def default_theme(:dark), do: "night-owl"
  def default_theme(_), do: "fresh-deck"

  @doc "Ordered list of `{slug, label}` for every selectable theme."
  def themes, do: @themes

  @doc "Allowlist of valid theme slugs (includes the dynamic per-game themes)."
  def theme_slugs do
    Enum.map(@game_themes, &elem(&1, 0)) ++ Enum.map(@themes, &elem(&1, 0))
  end

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
