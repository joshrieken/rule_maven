defmodule RuleMaven.Games.QuestionMismatchReport do
  @moduledoc """
  One "not my question" report, by one user, against one pooled answer.

  Exists so demotion can count DISTINCT reporters rather than clicks: the
  unique index on `{question_log_id, user_id}` is what stops a single account
  from un-pooling a correct answer by clicking three times.
  """
  use Ecto.Schema

  schema "question_mismatch_reports" do
    belongs_to :question_log, RuleMaven.Games.QuestionLog
    belongs_to :user, RuleMaven.Users.User

    timestamps(updated_at: false)
  end
end
