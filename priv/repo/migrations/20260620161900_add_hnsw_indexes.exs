defmodule RuleMaven.Repo.Migrations.AddHnswIndexes do
  use Ecto.Migration

  def up do
    execute """
    CREATE INDEX IF NOT EXISTS idx_chunks_embedding_hnsw
    ON chunks USING hnsw (embedding vector_cosine_ops)
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_faq_entries_embedding_hnsw
    ON faq_entries USING hnsw (question_embedding vector_cosine_ops)
    WHERE (question_embedding IS NOT NULL)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS idx_chunks_embedding_hnsw"
    execute "DROP INDEX IF EXISTS idx_faq_entries_embedding_hnsw"
  end
end
