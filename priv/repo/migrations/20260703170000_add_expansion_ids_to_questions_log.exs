defmodule RuleMaven.Repo.Migrations.AddExpansionIdsToQuestionsLog do
  use Ecto.Migration

  def change do
    alter table(:questions_log) do
      # The exact (sorted ascending) expansion-id set the answer was computed
      # against. [] = base game only. Cache lookups match on set equality;
      # invalidation matches membership (GIN index below).
      add :expansion_ids, {:array, :integer}, null: false, default: []
    end

    create index(:questions_log, [:expansion_ids], using: "GIN")
  end
end
