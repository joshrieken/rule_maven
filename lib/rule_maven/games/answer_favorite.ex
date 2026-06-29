defmodule RuleMaven.Games.AnswerFavorite do
  use Ecto.Schema
  import Ecto.Changeset

  schema "answer_favorites" do
    belongs_to :user, RuleMaven.Users.User
    belongs_to :question_log, RuleMaven.Games.QuestionLog

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(af, attrs) do
    af
    |> cast(attrs, [:user_id, :question_log_id])
    |> validate_required([:user_id, :question_log_id])
    |> unique_constraint([:user_id, :question_log_id])
  end
end
