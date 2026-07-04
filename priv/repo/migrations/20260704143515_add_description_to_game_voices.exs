defmodule RuleMaven.Repo.Migrations.AddDescriptionToGameVoices do
  use Ecto.Migration

  def change do
    alter table(:game_voices) do
      add :description, :text
    end
  end
end
