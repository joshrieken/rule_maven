defmodule RuleMaven.Repo.Migrations.AddDetailToLlmLogs do
  use Ecto.Migration

  def change do
    alter table(:llm_logs) do
      # Per-call context for the admin LLM-trace panel: input/output previews,
      # finish_reason, cached prompt tokens, token cap, retry flags.
      add :detail, :map
    end
  end
end
