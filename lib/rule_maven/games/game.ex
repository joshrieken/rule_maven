defmodule RuleMaven.Games.Game do
  use Ecto.Schema
  import Ecto.Changeset

  schema "games" do
    field :name, :string
    field :bgg_id, :integer
    field :year_published, :integer
    field :min_players, :integer
    field :max_players, :integer
    field :playing_time, :integer
    field :image_url, :string
    field :bgg_data, :string

    belongs_to :parent_game, RuleMaven.Games.Game, foreign_key: :parent_game_id
    has_many :expansions, RuleMaven.Games.Game, foreign_key: :parent_game_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(game, attrs) do
    game
    |> cast(attrs, [
      :name,
      :bgg_id,
      :year_published,
      :min_players,
      :max_players,
      :playing_time,
      :image_url,
      :parent_game_id,
      :bgg_data
    ])
    |> validate_required([:name])
  end
end
