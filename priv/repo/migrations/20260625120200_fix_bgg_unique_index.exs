defmodule RuleMaven.Repo.Migrations.FixBggUniqueIndex do
  use Ecto.Migration

  # A partial unique index (WHERE bgg_id IS NOT NULL) cannot be used as an
  # ON CONFLICT target. A plain unique index works because Postgres treats
  # NULLs as distinct, so manual games with null bgg_id are still allowed.
  def up do
    drop index(:games, [:bgg_id], name: :games_bgg_id_index)
    create unique_index(:games, [:bgg_id], name: :games_bgg_id_index)
  end

  def down do
    drop index(:games, [:bgg_id], name: :games_bgg_id_index)

    create unique_index(:games, [:bgg_id], where: "bgg_id IS NOT NULL", name: :games_bgg_id_index)
  end
end
