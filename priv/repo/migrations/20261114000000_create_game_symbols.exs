defmodule RuleMaven.Repo.Migrations.CreateGameSymbols do
  use Ecto.Migration

  def change do
    create table(:game_symbols) do
      add :game_id, references(:games, on_delete: :delete_all), null: false
      add :position, :integer, null: false, default: 0
      add :token, :string, null: false
      add :name, :string
      add :meaning, :text
      add :aliases, {:array, :string}, null: false, default: []
      add :page, :integer
      add :image_path, :string
      add :image_note, :string
      add :source, :string, null: false, default: "manual"

      timestamps(type: :utc_datetime)
    end

    create index(:game_symbols, [:game_id, :position])
    create unique_index(:game_symbols, [:game_id, :token])
  end
end
