defmodule RuleMaven.Repo.Migrations.AddCleanedQuestionToQuestionsLog do
  use Ecto.Migration

  def change do
    alter table(:questions_log) do
      add :cleaned_question, :text, null: true
    end
  end
end
