defmodule RuleMaven.Repo.Migrations.PerfAuditIndexes do
  use Ecto.Migration

  def up do
    # Serves the failed-questions anti-join in Games.recent_question_count/2
    # (billable-quota check — runs 3× per ask, inside the per-user advisory
    # lock). Failed rows are a tiny fraction of questions_log, so the partial
    # index stays small and hot.
    create index(:questions_log, [:id],
             where: "error_kind IS NOT NULL",
             name: :questions_log_failed_ids_idx
           )

    # Every game-page list query (recent_questions / faq_questions /
    # community_questions / refused_questions / unverified_pool_questions)
    # filters on game_id and orders by inserted_at DESC.
    create index(:questions_log, [:game_id, :inserted_at])

    # LLM.cost_in_window (runs on every job completion) and
    # cost_by_operation_for_game filter game_id + operation over a time window.
    create index(:llm_logs, [:game_id, :operation, :inserted_at])

    # The savings dashboard's cache-hit query: successful calls by operation,
    # per game, over a window.
    create index(:llm_logs, [:operation, :game_id, :inserted_at],
             where: "success = true",
             name: :llm_logs_savings_idx
           )

    # Lexical retrieval (Games.best_lexical_candidate/3 and
    # keyword_retrieve_multi/3) is now pushed into Postgres full-text search
    # instead of loading every published chunk into Elixir per ask; this GIN
    # expression index is what makes the @@ / ts_rank query index-served. The
    # expression must match the query fragment verbatim.
    execute """
    CREATE INDEX IF NOT EXISTS chunks_content_fts_idx
    ON chunks USING gin (to_tsvector('english', content))
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS chunks_content_fts_idx"

    drop_if_exists index(:llm_logs, [:operation, :game_id, :inserted_at],
                     name: :llm_logs_savings_idx
                   )

    drop_if_exists index(:llm_logs, [:game_id, :operation, :inserted_at])
    drop_if_exists index(:questions_log, [:game_id, :inserted_at])

    drop_if_exists index(:questions_log, [:id], name: :questions_log_failed_ids_idx)
  end
end
