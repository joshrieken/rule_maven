defmodule RuleMaven.Repo.Migrations.AddQuestionVotes do
  use Ecto.Migration

  def change do
    create table(:question_votes) do
      add :question_log_id, references(:questions_log, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :value, :string, null: false
      timestamps()
    end

    create unique_index(:question_votes, [:question_log_id, :user_id])
    create index(:question_votes, [:question_log_id])
  end
end
