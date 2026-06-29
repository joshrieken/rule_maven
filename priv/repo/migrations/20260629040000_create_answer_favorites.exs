defmodule RuleMaven.Repo.Migrations.CreateAnswerFavorites do
  use Ecto.Migration

  def change do
    create table(:answer_favorites) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :question_log_id, references(:questions_log, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:answer_favorites, [:user_id, :question_log_id])
    create index(:answer_favorites, [:question_log_id])
  end
end
