defmodule RuleMaven.Repo.Migrations.AddErrorTrackingToQuestionLogs do
  use Ecto.Migration

  def change do
    alter table(:questions_log) do
      # Machine-readable failure classification, set alongside the human-facing
      # "⚠️ ..." answer text. nil for normal answers. Drives the player-facing
      # retry affordance and exempts failed asks from the billable quota count.
      add :error_kind, :string
      # How many player-visible retries this question has already consumed.
      # Retries delete + recreate the row, so the count is carried forward.
      add :error_retries, :integer, default: 0, null: false
    end
  end
end
