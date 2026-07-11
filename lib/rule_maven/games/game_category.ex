defmodule RuleMaven.Games.GameCategory do
  use Ecto.Schema
  import Ecto.Changeset

  schema "game_categories" do
    belongs_to :game, RuleMaven.Games.Game
    field :name, :string
    field :description, :string
    field :name_embedding, Pgvector.Ecto.Vector
    timestamps()
  end

  def changeset(cat, attrs) do
    cat
    |> cast(attrs, [:game_id, :name, :description, :name_embedding])
    |> validate_required([:game_id, :name])
    |> validate_length(:name, max: 200)
    |> validate_length(:description, max: 2000)
  end
end
