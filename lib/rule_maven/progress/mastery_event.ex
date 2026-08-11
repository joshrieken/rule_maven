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
    # nil while the `:mastery_levels` flag is off for this user: the event is
    # banked but not yet folded into `game_mastery` / `curator_points`. The
    # backfill stamps it when the flag comes on.
    field :applied_at, :utc_datetime
    belongs_to :user, RuleMaven.Users.User
    belongs_to :game, RuleMaven.Games.Game

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:user_id, :game_id, :source_key, :kind, :xp, :applied_at])
    |> validate_required([:user_id, :game_id, :source_key, :kind, :xp])
    |> unique_constraint([:user_id, :source_key], name: :mastery_events_user_id_source_key_index)
  end
end
