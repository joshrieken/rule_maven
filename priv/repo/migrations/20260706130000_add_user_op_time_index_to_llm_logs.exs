defmodule RuleMaven.Repo.Migrations.AddUserOpTimeIndexToLlmLogs do
  use Ecto.Migration

  def change do
    create index(:llm_logs, [:user_id, :operation, :inserted_at])
  end
end
