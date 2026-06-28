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
    field :image_url, :string
    field :bgg_data, :string
    field :category, :string, default: "board_game"
    # Per-game theme derived from the BGG cover image. See ThemePaletteWorker.
    # %{"light" => %{"--bg" => "#…", …}, "dark" => %{…}}
    field :theme_palette, :map

    # Lightweight DMCA takedown. When `taken_down_at` is set the game is hidden
    # from listings and new asks are blocked; reason + complainant are recorded
    # for the takedown log. Cleared to restore.
    field :taken_down_at, :utc_datetime
    field :takedown_reason, :string
    field :takedown_complainant, :string

    belongs_to :parent_game, RuleMaven.Games.Game, foreign_key: :parent_game_id
    has_many :expansions, RuleMaven.Games.Game, foreign_key: :parent_game_id

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
      :image_url,
      :parent_game_id,
      :bgg_data,
      :category,
      :theme_palette
    ])
    |> validate_required([:name])
  end
end
