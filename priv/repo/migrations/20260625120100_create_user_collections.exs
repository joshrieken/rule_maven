defmodule RuleMaven.Repo.Migrations.CreateUserCollections do
  use Ecto.Migration

  # Per-user ownership overlay on the global catalog.
  def change do
    create table(:user_collections) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :game_id, references(:games, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_collections, [:user_id, :game_id])
    create index(:user_collections, [:game_id])
  end
end
