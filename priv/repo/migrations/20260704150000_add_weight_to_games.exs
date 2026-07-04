defmodule RuleMaven.Repo.Migrations.AddWeightToGames do
  use Ecto.Migration

  def change do
    alter table(:games) do
      add :weight, :float
    end
  end
end
