defmodule RuleMaven.Metrics do
  @moduledoc """
  Usage metrics. Currently tracks theme selections so we can see which themes
  people actually pick.
  """

  import Ecto.Query
  alias RuleMaven.Repo
  alias RuleMaven.Metrics.ThemeEvent

  # Slug -> human label -> scheme, alphabetical by label. The slug is the
  # `data-theme` value AND the kebab-case of the label — one canonical name per
  # theme, no drift. This list is the single source of truth: the picker, the
  # CSS `[data-theme="…"]` blocks, and the allowlist all derive from it.
  #
  # `scheme` must match the `color-scheme` of the theme's CSS block; it groups
  # the picker into Light/Dark optgroups. `theme_scheme_test` pins the two.
  @themes [
    {"black-hole", "Black Hole", :dark},
    {"campfire", "Campfire", :dark},
    {"cheat-code", "Cheat Code", :dark},
    {"chess-club", "Chess Club", :light},
    {"deep-space", "Deep Space", :dark},
    {"dungeon-master", "Dungeon Master", :light},
    {"flamingo", "Flamingo", :light},
    {"fresh-deck", "Fresh Deck", :light},
    {"grave-digger", "Grave Digger", :dark},
    {"honeycomb", "Honeycomb", :light},
    {"insert-coin", "Insert Coin", :dark},
    {"kraken", "Kraken", :dark},
    {"last-turn", "Last Turn", :dark},
    {"lemonade", "Lemonade", :light},
    {"mixtape", "Mixtape", :dark},
    {"moonrise", "Moonrise", :dark},
    {"night-owl", "Night Owl", :dark},
    {"overgrowth", "Overgrowth", :dark},
    {"picnic", "Picnic", :light},
    {"snow-day", "Snow Day", :light},
    {"steamworks", "Steamworks", :dark}
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
  def themes, do: Enum.map(@themes, fn {slug, label, _scheme} -> {slug, label} end)

  @doc """
  The static themes grouped for the picker: `[{:light, [{slug, label}, …]},
  {:dark, …}]`. Light first — it's the default for a fresh visitor.
  """
  def themes_by_scheme do
    for scheme <- [:light, :dark] do
      {scheme,
       for {slug, label, ^scheme} <- @themes do
         {slug, label}
       end}
    end
  end

  @doc "Allowlist of valid theme slugs (includes the dynamic per-game themes)."
  def theme_slugs do
    Enum.map(@game_themes, &elem(&1, 0)) ++ Enum.map(@themes, &elem(&1, 0))
  end

  @doc "Map of slug => label."
  def theme_labels, do: Map.new(themes())

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
