defmodule RuleMaven.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs) do
      # Actor is denormalized: the username is snapshotted so the log stays
      # readable after the user row is deleted. actor_id is nilified on delete.
      add :actor_id, references(:users, on_delete: :nilify_all)
      add :actor_username, :string
      add :action, :string, null: false
      add :target_type, :string
      add :target_id, :integer
      add :target_label, :string
      add :metadata, :map, default: %{}

      # Append-only: no updated_at.
      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:audit_logs, [:inserted_at])
    create index(:audit_logs, [:actor_id])
    create index(:audit_logs, [:target_type, :target_id])
    create index(:audit_logs, [:action])
  end
end
