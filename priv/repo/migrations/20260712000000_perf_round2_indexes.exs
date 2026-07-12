defmodule RuleMaven.Repo.Migrations.PerfRound2Indexes do
  use Ecto.Migration

  @moduledoc """
  `Audit.question_history/2` filters audit_logs on `action = 'question.delete'
  AND target_type = 'question' AND metadata->>'game_id' = $1`. None of the
  existing btree indexes (action alone, target_type+target_id, inserted_at)
  can serve the JSONB game_id predicate, so every admin history click scanned
  all question-delete rows — a set that grows with every regenerate, since
  regeneration hard-deletes the replaced row.

  A partial expression index over exactly that predicate serves the lookup:
  partial on the two constant filters, keyed on the JSONB game_id expression.
  Column names verified against 20260628070000_create_audit_logs.exs
  (`action`, `target_type`, `metadata`).
  """

  def change do
    create index(:audit_logs, ["(metadata->>'game_id')"],
             where: "action = 'question.delete' AND target_type = 'question'",
             name: :audit_logs_qdelete_game_idx
           )
  end
end
