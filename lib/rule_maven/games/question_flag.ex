defmodule RuleMaven.Games.QuestionFlag do
  use Ecto.Schema
  import Ecto.Changeset

  schema "question_flags" do
    field :reason, :string
    field :resolved, :boolean, default: false
    belongs_to :question_log, RuleMaven.Games.QuestionLog
    belongs_to :user, RuleMaven.Users.User

    timestamps(type: :utc_datetime)
  end

  def changeset(flag, attrs) do
    flag
    |> cast(attrs, [:question_log_id, :user_id, :reason, :resolved])
    |> validate_required([:question_log_id, :user_id])
    |> validate_length(:reason, max: 280)
    |> unique_constraint([:user_id, :question_log_id])
  end
end
