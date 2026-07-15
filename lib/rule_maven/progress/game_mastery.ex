defmodule RuleMaven.Progress.GameMastery do
  @moduledoc """
  Denormalized per-(user, game) rollup: the mastery bar total, current level,
  and the slugs of any personas unlocked by leveling this game.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "game_mastery" do
    field :xp, :integer, default: 0
    field :level, :integer, default: 0
    field :unlocked_voice_slugs, {:array, :string}, default: []
    belongs_to :user, RuleMaven.Users.User
    belongs_to :game, RuleMaven.Games.Game

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(mastery, attrs) do
    mastery
    |> cast(attrs, [:user_id, :game_id, :xp, :level, :unlocked_voice_slugs])
    |> validate_required([:user_id, :game_id, :xp, :level])
    |> unique_constraint([:user_id, :game_id], name: :game_mastery_user_id_game_id_index)
  end
end
