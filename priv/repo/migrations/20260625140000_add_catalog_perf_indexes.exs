defmodule RuleMaven.Repo.Migrations.AddCatalogPerfIndexes do
  use Ecto.Migration

  # The catalog grew to ~150k games. Two hot paths did sequential scans:
  #   - document lookups by game_id (list_documents / list_rulebook_sources /
  #     the "playable" join) on every games-list and edit-page load;
  #   - the "All Games" view orders the whole catalog by bgg_rank.
  def change do
    create_if_not_exists index(:documents, [:game_id])
    create_if_not_exists index(:games, [:bgg_rank])
  end
end
