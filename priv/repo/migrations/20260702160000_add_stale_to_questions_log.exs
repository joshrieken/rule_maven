defmodule RuleMaven.Repo.Migrations.AddStaleToQuestionsLog do
  use Ecto.Migration

  # Separates "rulebook content changed underneath this cached answer" (stale)
  # from "flagged for moderator review" (needs_review) — see games.ex
  # invalidate_pool/1. Previously invalidate_pool overloaded needs_review for
  # both purposes, which inflated moderation.ex's per-user abuse-risk score
  # every time a rulebook edit invalidated ordinary askers' private answers.
  def change do
    alter table(:questions_log) do
      add :stale, :boolean, null: false, default: false
    end
  end
end
