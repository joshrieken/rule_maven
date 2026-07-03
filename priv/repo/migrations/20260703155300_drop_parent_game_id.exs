defmodule RuleMaven.Repo.Migrations.DropParentGameId do
  use Ecto.Migration

  def up do
    alter table(:games), do: remove(:parent_game_id)
  end

  def down do
    alter table(:games) do
      add :parent_game_id, references(:games, on_delete: :nilify_all)
    end
  end
end
