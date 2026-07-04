defmodule RuleMaven.Games.ExpansionSelection do
  @moduledoc """
  A user's remembered per-base-game expansion choice. One row per
  {user, base game}; `expansion_ids` is the sorted set they play with.
  Row absent = never chosen (UI then defaults from the user's collection);
  `[]` = an explicit "base game only" choice.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "expansion_selections" do
    field :expansion_ids, {:array, :integer}, default: []
    belongs_to :user, RuleMaven.Users.User
    belongs_to :game, RuleMaven.Games.Game

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(sel, attrs) do
    sel
    |> cast(attrs, [:user_id, :game_id, :expansion_ids])
    |> validate_required([:user_id, :game_id])
    |> unique_constraint([:user_id, :game_id])
  end
end
