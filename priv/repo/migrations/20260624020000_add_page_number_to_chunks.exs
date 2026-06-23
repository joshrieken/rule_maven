defmodule RuleMaven.Repo.Migrations.AddPageNumberToChunks do
  use Ecto.Migration

  def change do
    alter table(:chunks) do
      add :page_number, :integer, null: true
    end

    create index(:chunks, [:page_number])
  end
end
