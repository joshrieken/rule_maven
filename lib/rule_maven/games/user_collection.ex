defmodule RuleMaven.Games.UserCollection do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_collections" do
    belongs_to :user, RuleMaven.Users.User
    belongs_to :game, RuleMaven.Games.Game

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(uc, attrs) do
    uc
    |> cast(attrs, [:user_id, :game_id])
    |> validate_required([:user_id, :game_id])
    |> unique_constraint([:user_id, :game_id])
  end
end
