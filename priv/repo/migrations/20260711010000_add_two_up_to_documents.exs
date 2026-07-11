defmodule RuleMaven.Repo.Migrations.AddTwoUpToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :two_up, :boolean, default: false, null: false
    end
  end
end
