defmodule RuleMaven.Repo.Migrations.CreateAnswerVoices do
  use Ecto.Migration

  def change do
    create table(:answer_voices) do
      add :question_log_id, references(:questions_log, on_delete: :delete_all), null: false
      add :voice, :string, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime)
    end

    # One cached restyle per (answer, voice). Globally shared: once generated for
    # an answer, every viewer of that answer reuses it.
    create unique_index(:answer_voices, [:question_log_id, :voice])
  end
end
