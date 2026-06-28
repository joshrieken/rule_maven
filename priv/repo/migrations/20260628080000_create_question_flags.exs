defmodule RuleMaven.Repo.Migrations.CreateQuestionFlags do
  use Ecto.Migration

  def change do
    create table(:question_flags) do
      add :question_log_id, references(:questions_log, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :reason, :string
      # Flags stay until an admin resolves them; re-flagging a resolved row
      # re-opens it (see Games.flag_question upsert).
      add :resolved, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    # One flag per user per answer; re-flag upserts.
    create unique_index(:question_flags, [:user_id, :question_log_id])
    create index(:question_flags, [:question_log_id])
    create index(:question_flags, [:resolved])
  end
end
