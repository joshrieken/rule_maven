defmodule RuleMaven.Repo.Migrations.CreateReextractLogs do
  use Ecto.Migration

  def change do
    create table(:reextract_logs) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :text, :string, null: false
      # info | warn | done | error — drives the line's colour (shared with the
      # ingest log panel).
      add :kind, :string, null: false, default: "info"

      timestamps(updated_at: false)
    end

    # Read path: all lines for a source document in insertion order.
    create index(:reextract_logs, [:document_id, :id])
  end
end
