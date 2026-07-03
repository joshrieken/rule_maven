defmodule RuleMaven.Repo.Migrations.CreateGameExpansionLinks do
  use Ecto.Migration

  def up do
    create table(:game_expansion_links) do
      add :expansion_id, references(:games, on_delete: :delete_all), null: false
      add :base_game_id, references(:games, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:game_expansion_links, [:expansion_id, :base_game_id])
    create index(:game_expansion_links, [:base_game_id])

    # Backfill from the legacy single-parent FK (column dropped in a later migration).
    execute """
    INSERT INTO game_expansion_links (expansion_id, base_game_id, inserted_at, updated_at)
    SELECT id, parent_game_id, NOW(), NOW() FROM games WHERE parent_game_id IS NOT NULL
    """
  end

  def down do
    drop table(:game_expansion_links)
  end
end
