defmodule RuleMaven.Repo.Migrations.CreateQuestionMismatchReports do
  use Ecto.Migration

  # `mismatch_count` was a bare counter bumped on every "Ask exactly this"
  # click, and it now drives an automatic demotion. A raw click count is
  # sockpuppet-cheap: pool-hit asks are quota-exempt, so N throwaway accounts
  # (or one account clicking N times) could un-pool a correct, popular answer
  # for free. Demotion must count DISTINCT reporters, which needs a row per
  # (question, reporter) with a uniqueness guarantee.
  def change do
    create table(:question_mismatch_reports) do
      add :question_log_id, references(:questions_log, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(updated_at: false)
    end

    create unique_index(:question_mismatch_reports, [:question_log_id, :user_id])
    create index(:question_mismatch_reports, [:question_log_id])
  end
end
