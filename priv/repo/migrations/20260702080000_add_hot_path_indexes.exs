defmodule RuleMaven.Repo.Migrations.AddHotPathIndexes do
  use Ecto.Migration

  def up do
    # Index questions_log.question_embedding with HNSW for similarity search
    # Mirrors chunks embedding index from 20260620161900_add_hnsw_indexes.exs
    execute """
    CREATE INDEX IF NOT EXISTS idx_questions_log_embedding_hnsw
    ON questions_log USING hnsw (question_embedding vector_cosine_ops)
    WHERE (question_embedding IS NOT NULL)
    """

    # Index chunks.document_id — filtered in chunk_document, EmbedChunksWorker, Readiness.doc_embedded?
    create index(:chunks, [:document_id], concurrently: false)

    # Composite index for recent_question_count filter on user_id + inserted_at
    create index(:questions_log, [:user_id, :inserted_at], concurrently: false)
  end

  def down do
    drop_if_exists index(:questions_log, [:user_id, :inserted_at])
    drop_if_exists index(:chunks, [:document_id])
    execute "DROP INDEX IF EXISTS idx_questions_log_embedding_hnsw"
  end
end
