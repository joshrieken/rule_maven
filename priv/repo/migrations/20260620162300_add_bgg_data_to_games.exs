defmodule RuleMaven.Repo.Migrations.AddBggDataToGames do
  use Ecto.Migration

  def change do
    alter table(:games) do
      add :bgg_data, :text
    end
  end
end
