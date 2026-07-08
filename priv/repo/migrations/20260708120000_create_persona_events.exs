defmodule RuleMaven.Repo.Migrations.CreatePersonaEvents do
  use Ecto.Migration

  def change do
    create table(:persona_events) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :game_id, references(:games, on_delete: :delete_all), null: false
      # Voice/persona id as used in the picker: "neutral", "court-case", "g:slug".
      add :voice_id, :string, null: false
      timestamps(updated_at: false)
    end

    # Popularity: count by (game_id, voice_id). Recency: newest per user.
    create index(:persona_events, [:game_id, :voice_id])
    create index(:persona_events, [:user_id, :inserted_at])
  end
end
