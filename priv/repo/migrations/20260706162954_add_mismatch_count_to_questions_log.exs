defmodule RuleMaven.Repo.Migrations.AddMismatchCountToQuestionsLog do
  use Ecto.Migration

  def change do
    alter table(:questions_log) do
      # Times a pool/cache serve of this row was reported "not my question" by
      # the asker. A tuning signal for the pool-matching thresholds and a
      # per-row flag for canonical text that matches too greedily.
      add :mismatch_count, :integer, default: 0, null: false
    end
  end
end
