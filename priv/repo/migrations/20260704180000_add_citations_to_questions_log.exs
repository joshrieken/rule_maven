defmodule RuleMaven.Repo.Migrations.AddCitationsToQuestionsLog do
  use Ecto.Migration

  def change do
    alter table(:questions_log) do
      add :citations, {:array, :map}, default: [], null: false
    end
  end
end
