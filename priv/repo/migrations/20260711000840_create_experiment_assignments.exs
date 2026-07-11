defmodule RuleMaven.Repo.Migrations.CreateExperimentAssignments do
  use Ecto.Migration

  def change do
    create table(:experiment_assignments) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :experiment, :string, null: false
      add :variant, :string, null: false

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create unique_index(:experiment_assignments, [:user_id, :experiment])
    create index(:experiment_assignments, [:experiment, :variant])
  end
end
