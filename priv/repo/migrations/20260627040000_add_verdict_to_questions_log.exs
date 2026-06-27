defmodule RuleMaven.Repo.Migrations.AddVerdictToQuestionsLog do
  use Ecto.Migration

  def change do
    alter table(:questions_log) do
      # One of: "legal" | "illegal" | "silent" | "info" | nil.
      # Drives the answer verdict stamp (✅ legal move / ❌ not allowed /
      # 🤔 rules silent / 📖 info). Classified by the LLM as it answers.
      add :verdict, :string
    end
  end
end
