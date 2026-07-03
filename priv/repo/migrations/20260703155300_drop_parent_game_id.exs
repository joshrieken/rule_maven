defmodule RuleMaven.Repo.Migrations.DropParentGameId do
  use Ecto.Migration

  def up do
    alter table(:games), do: remove(:parent_game_id)
  end

  def down do
    alter table(:games) do
      add :parent_game_id, references(:games, on_delete: :nilify_all)
    end

    # Backfill from the authoritative join table so rolling back doesn't
    # silently lose the base<->expansion relationship that was only tracked
    # via game_expansion_links after the "up" migration ran.
    execute """
    UPDATE games
    SET parent_game_id = (
      SELECT min(base_game_id)
      FROM game_expansion_links
      WHERE expansion_id = games.id
    )
    """
  end
end
