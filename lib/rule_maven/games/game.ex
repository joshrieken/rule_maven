defmodule RuleMaven.Games.Game do
  use Ecto.Schema
  import Ecto.Changeset

  schema "games" do
    field :name, :string
    field :bgg_id, :integer
    field :bgg_rank, :integer
    field :year_published, :integer
    field :min_players, :integer
    field :max_players, :integer
    field :playing_time, :integer
    field :weight, :float
    field :image_url, :string
    field :bgg_data, :string
    field :category, :string, default: "board_game"
    # Per-game theme derived from the BGG cover image. See ThemePaletteWorker.
    # %{"light" => %{"--bg" => "#…", …}, "dark" => %{…}}
    field :theme_palette, :map
    # Player-facing names for the two palette variants, generated with it.
    # %{"light" => "Harbor Daylight", "dark" => "Longest Night"}. Nil until a
    # palette is (re)generated; the picker falls back to "Game Light"/"Game Dark".
    field :theme_names, :map

    # Readiness: `playable` is the denormalized end-of-pipeline flag (RAG-ready
    # *and* reviewed), recomputed by `RuleMaven.Readiness`. Indexed; the catalog
    # "Playable" list filters on it instead of a per-row document join.
    field :playable, :boolean, default: false
    field :playable_at, :utc_datetime

    # Lightweight DMCA takedown. When `taken_down_at` is set the game is hidden
    # from listings and new asks are blocked; reason + complainant are recorded
    # for the takedown log. Cleared to restore.
    field :taken_down_at, :utc_datetime
    field :takedown_reason, :string
    field :takedown_complainant, :string

    timestamps(type: :utc_datetime)
  end

  @doc "True while the game is under a DMCA takedown."
  def taken_down?(%__MODULE__{taken_down_at: nil}), do: false
  def taken_down?(%__MODULE__{taken_down_at: _}), do: true
  def taken_down?(_), do: false

  @doc false
  def changeset(game, attrs) do
    game
    |> cast(attrs, [
      :name,
      :bgg_id,
      :bgg_rank,
      :year_published,
      :min_players,
      :max_players,
      :playing_time,
      :weight,
      :image_url,
      :bgg_data,
      :category,
      :theme_palette,
      :theme_names
    ])
    |> validate_required([:name])
    |> validate_length(:name, max: 300)
    |> validate_number(:year_published, greater_than_or_equal_to: 1400, less_than_or_equal_to: 2200)
    |> validate_number(:min_players, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:max_players, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:playing_time, greater_than_or_equal_to: 0, less_than_or_equal_to: 100_000)
    |> validate_number(:weight, greater_than_or_equal_to: 0, less_than_or_equal_to: 5)
    |> validate_number(:bgg_rank, greater_than_or_equal_to: 0)
  end
end

# URLs reference games by an opaque token, never the raw integer id.
defimpl Phoenix.Param, for: RuleMaven.Games.Game do
  def to_param(%{id: id}), do: RuleMaven.Hashid.encode(id)
end
