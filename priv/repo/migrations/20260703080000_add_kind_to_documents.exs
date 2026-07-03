defmodule RuleMaven.Repo.Migrations.AddKindToDocuments do
  use Ecto.Migration

  def up do
    alter table(:documents) do
      add :kind, :string, null: false, default: "rulebook"
      remove :is_core
    end
  end

  def down do
    alter table(:documents) do
      remove :kind
      add :is_core, :boolean, default: false
    end
  end
end
