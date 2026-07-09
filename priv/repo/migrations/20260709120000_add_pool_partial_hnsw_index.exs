defmodule RuleMaven.Repo.Migrations.AddPoolPartialHnswIndex do
  use Ecto.Migration

  # The existing idx_questions_log_embedding_hnsw covers every row with an
  # embedding, but the pool lookup only ever reads rows that are pooled or
  # community and not refused/needs_review/stale. As the served fraction of
  # questions_log shrinks, pgvector has to walk further down the index to fill
  # its LIMIT, and the failure mode is silent recall loss (a real match is
  # never returned) rather than a slow query. A partial index over exactly the
  # serve predicate keeps the search confined to servable rows.
  #
  # `stale` and `needs_review` are mutable, so they cannot live in the index
  # predicate (a row flipping to stale would need a reindex to leave). Only the
  # stable eligibility columns go here; the mutable filters stay in the query.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_questions_log_pool_embedding_hnsw
    ON questions_log USING hnsw (question_embedding vector_cosine_ops)
    WHERE (question_embedding IS NOT NULL AND refused = false
           AND (pooled = true OR visibility = 'community'))
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_questions_log_pool_embedding_hnsw"
  end
end
