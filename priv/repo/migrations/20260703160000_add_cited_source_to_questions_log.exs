defmodule RuleMaven.Repo.Migrations.AddCitedSourceToQuestionsLog do
  use Ecto.Migration

  def change do
    alter table(:questions_log) do
      add :cited_source, :string
    end
  end
end
