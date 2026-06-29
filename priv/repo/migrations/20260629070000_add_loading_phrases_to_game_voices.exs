defmodule RuleMaven.Repo.Migrations.AddLoadingPhrasesToGameVoices do
  use Ecto.Migration

  def change do
    alter table(:game_voices) do
      add :loading_phrases, {:array, :text}, default: []
    end
  end
end
