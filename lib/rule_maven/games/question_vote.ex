defmodule RuleMaven.Games.QuestionVote do
  use Ecto.Schema
  import Ecto.Changeset

  schema "question_votes" do
    belongs_to :question_log, RuleMaven.Games.QuestionLog
    belongs_to :user, RuleMaven.Users.User
    field :value, :string
    field :weight, :float, default: 1.0
    field :settled_at, :utc_datetime
    field :settled_outcome, :string

    timestamps()
  end

  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:question_log_id, :user_id, :value, :weight])
    |> validate_required([:question_log_id, :user_id, :value])
    |> validate_inclusion(:value, ["up", "down"])
    |> unique_constraint([:question_log_id, :user_id])
  end
end
