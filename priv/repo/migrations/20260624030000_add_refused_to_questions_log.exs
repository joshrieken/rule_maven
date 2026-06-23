defmodule RuleMaven.Repo.Migrations.AddRefusedToQuestionsLog do
  use Ecto.Migration

  def change do
    alter table(:questions_log) do
      add :refused, :boolean, null: false, default: false
    end

    create index(:questions_log, [:refused])
  end
end
