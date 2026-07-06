defmodule RuleMaven.Repo.Migrations.AddQuestionLogIdToLlmLogs do
  use Ecto.Migration

  def change do
    alter table(:llm_logs) do
      # Plain bigint, no FK: llm_logs is audit data and must survive
      # question-row deletion (regenerate and dedup both delete rows).
      add :question_log_id, :bigint
    end

    create index(:llm_logs, [:question_log_id])
  end
end
