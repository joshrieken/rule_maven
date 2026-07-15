defmodule RuleMaven.Progress.MasteryEvent do
  @moduledoc """
  Append-only ledger row: one XP grant to a user for a game.

  The unique index on `(user_id, source_key)` is the per-user anti-farm dedupe —
  a user earns at most once per canonical answer, no matter how many cache hits
  or concurrent asks land on it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "mastery_events" do
    field :source_key, :string
    field :kind, :string
    field :xp, :integer
    belongs_to :user, RuleMaven.Users.User
    belongs_to :game, RuleMaven.Games.Game

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:user_id, :game_id, :source_key, :kind, :xp])
    |> validate_required([:user_id, :game_id, :source_key, :kind, :xp])
    |> unique_constraint([:user_id, :source_key], name: :mastery_events_user_id_source_key_index)
  end
end
