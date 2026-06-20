defmodule RuleMaven.Repo.Migrations.AddParentGameIdToGames do
  use Ecto.Migration

  def change do
    alter table(:games) do
      add :parent_game_id, references(:games, on_delete: :nilify_all)
    end

    create index(:games, [:parent_game_id])
  end
end
