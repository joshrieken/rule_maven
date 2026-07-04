defmodule RuleMaven.Repo.Migrations.CreateExpansionSelections do
  use Ecto.Migration

  def change do
    create table(:expansion_selections) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :game_id, references(:games, on_delete: :delete_all), null: false
      # Sorted ascending; [] is a meaningful explicit "base only" choice.
      add :expansion_ids, {:array, :integer}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:expansion_selections, [:user_id, :game_id])
  end
end
