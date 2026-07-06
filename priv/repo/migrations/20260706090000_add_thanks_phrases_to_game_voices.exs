defmodule RuleMaven.Repo.Migrations.AddThanksPhrasesToGameVoices do
  use Ecto.Migration

  def change do
    alter table(:game_voices) do
      add :thanks_phrases, {:array, :string}, default: [], null: false
    end
  end
end
