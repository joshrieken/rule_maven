defmodule RuleMaven.Repo.Migrations.AddVettedToGameVoices do
  use Ecto.Migration

  def change do
    alter table(:game_voices) do
      # True once a separate LLM vet pass has judged the generated style string
      # to be a pure tone description (no smuggled instructions), which allows
      # it to be interpolated into the rulebook-access ask prompt for the
      # single-call persona path. Unvetted voices keep the restyle path.
      add :vetted, :boolean, null: false, default: false
    end
  end
end
