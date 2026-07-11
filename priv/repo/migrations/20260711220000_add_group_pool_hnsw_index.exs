defmodule RuleMaven.Repo.Migrations.AddGroupPoolHnswIndex do
  use Ecto.Migration

  @moduledoc """
  The crew branch of `find_pool_candidates/3` cannot use the existing partial
  HNSW index, so the crew's own private cache degrades to near-zero recall.

  The non-crew predicate is `pooled OR (community AND citation_valid)`, which
  implies the index predicate on `20260709120000` (`pooled = true OR visibility =
  'community'`) — so the planner can use it. The crew query adds a third disjunct:

      pooled OR (community AND citation_valid) OR (group_id = $1 AND citation_valid)

  `A OR (B AND C) OR (D AND E)` does not imply `A OR B`, so that index is
  unusable for a crew ask — and crew rows are `pooled: false, visibility: 'private'`
  until the screen clears them, so they are not IN it anyway.

  The planner falls back to the full embedding index and walks the global HNSW
  graph with `ef_search` over every embedded row in the table; a crew's dozen rows
  are very unlikely to surface in the global top-40. The crew cache misses and the
  member pays for a full LLM ask — silently, since a miss looks like a miss.

  This is the same recall loss `20260709120000` was created to prevent, for the one
  branch the feature exists to serve.
  """

  # CONCURRENTLY cannot run inside a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_questions_log_group_pool_hnsw
    ON questions_log USING hnsw (question_embedding vector_cosine_ops)
    WHERE question_embedding IS NOT NULL
      AND refused = false
      AND group_id IS NOT NULL
      AND citation_valid = true
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS idx_questions_log_group_pool_hnsw")
  end
end
