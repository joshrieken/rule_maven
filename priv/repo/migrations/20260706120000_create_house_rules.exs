defmodule RuleMaven.Repo.Migrations.CreateHouseRules do
  use Ecto.Migration

  def change do
    create table(:house_rules) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :game_id, references(:games, on_delete: :delete_all), null: false
      add :title, :string
      add :body, :text, null: false
      add :visibility, :string, null: false, default: "private"
      add :check_status, :string, null: false, default: "pending"
      add :verdict, :string
      add :raw_quote, :text
      add :check_note, :text
      add :citations, {:array, :map}, default: []
      add :checked_at, :utc_datetime
      add :blocked, :boolean, null: false, default: false

      timestamps()
    end

    create index(:house_rules, [:game_id, :visibility])
    create index(:house_rules, [:user_id, :game_id])
  end
end
