defmodule RuleMaven.Repo.Migrations.V2SchemaUpgrade do
  use Ecto.Migration

  def up do
    # ── documents (was rulebook_sources) ──
    rename table(:rulebook_sources), to: table(:documents)

    alter table(:documents) do
      add :version, :integer, null: false, default: 1
      add :cheatsheet, :text
      add :status, :text, null: false, default: "pending_review"
      add :file_hash, :text
      add :reviewed_by, references(:users)
      add :reviewed_at, :utc_datetime
    end

    # ── chunks (was rulebook_chunks) ──
    rename table(:rulebook_chunks), to: table(:chunks)

    alter table(:chunks) do
      add :embedding, :vector, size: 768
      add :section_label, :text
    end

    # Rename source_id → document_id
    execute "ALTER TABLE chunks RENAME COLUMN source_id TO document_id"

    # Drop game_id (denormalized via document)
    execute "ALTER TABLE chunks DROP COLUMN game_id"

    # ── questions_log additions ──
    alter table(:questions_log) do
      add :question_embedding, :vector, size: 768
      add :source_chunk_ids, {:array, :bigint}
      add :feedback, :text
      add :cluster_id, :bigint
      add :document_id, references(:documents)
    end

    # ── faq_entries ──
    create table(:faq_entries) do
      add :game_id, references(:games, on_delete: :delete_all), null: false
      add :canonical_question, :text, null: false
      add :canonical_answer, :text, null: false
      add :question_embedding, :vector, size: 768
      add :source_qa_ids, {:array, :bigint}, null: false
      add :status, :text, null: false, default: "draft"
      add :auto_approved, :boolean, null: false, default: false
      add :auto_approve_reason, :text
      add :approved_by, references(:users)
      add :approved_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:faq_entries, [:game_id])
    create index(:faq_entries, [:status])

    # Backfill: set existing documents + chunks as published
    execute "UPDATE documents SET status = 'published', version = 1"
  end

  def down do
    drop table(:faq_entries)

    alter table(:questions_log) do
      remove :document_id
      remove :cluster_id
      remove :feedback
      remove :source_chunk_ids
      remove :question_embedding
    end

    execute "ALTER TABLE chunks ADD COLUMN game_id bigint REFERENCES games(id)"
    execute "ALTER TABLE chunks RENAME COLUMN document_id TO source_id"

    alter table(:chunks) do
      remove :section_label
      remove :embedding
    end

    rename table(:chunks), to: table(:rulebook_chunks)

    alter table(:documents) do
      remove :reviewed_at
      remove :reviewed_by
      remove :file_hash
      remove :status
      remove :cheatsheet
      remove :version
    end

    rename table(:documents), to: table(:rulebook_sources)
  end
end
