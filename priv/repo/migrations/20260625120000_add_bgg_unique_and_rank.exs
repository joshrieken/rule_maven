defmodule RuleMaven.Repo.Migrations.AddBggUniqueAndRank do
  use Ecto.Migration

  # Unique bgg_id enables upsert on catalog import (insert_all on_conflict);
  # bgg_rank stores the dump's popularity rank for catalog ordering.
  def change do
    alter table(:games) do
      add :bgg_rank, :integer
    end

    create unique_index(:games, [:bgg_id], where: "bgg_id IS NOT NULL", name: :games_bgg_id_index)
  end
end
