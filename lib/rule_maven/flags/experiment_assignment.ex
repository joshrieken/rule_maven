defmodule RuleMaven.Flags.ExperimentAssignment do
  @moduledoc """
  One immutable row per (user, experiment): the A/B variant a user was first
  assigned to, and when. Written by `RuleMaven.Flags.variant/2`. Metric-agnostic
  — outcome analysis joins this table by `user_id` + `inserted_at` later.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "experiment_assignments" do
    belongs_to :user, RuleMaven.Users.User
    field :experiment, :string
    field :variant, :string

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:user_id, :experiment, :variant])
    |> validate_required([:user_id, :experiment, :variant])
    |> validate_inclusion(:variant, ["control", "treatment"])
    |> unique_constraint([:user_id, :experiment], name: :experiment_assignments_user_id_experiment_index)
  end
end
