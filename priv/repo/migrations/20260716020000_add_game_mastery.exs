defmodule RuleMaven.Repo.Migrations.AddGameMastery do
  use Ecto.Migration

  def change do
    # Append-only ledger of every XP grant. Doubles as:
    #   - the per-user anti-farm dedupe (unique index on user_id + source_key),
    #   - the "recent XP" feed, and
    #   - the audit trail for how a mastery total was earned.
    create table(:mastery_events) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :game_id, references(:games, on_delete: :delete_all), null: false
      # Canonical answer identity the user landed on (question_logs.pool_source_id
      # || question_logs.id). A row's presence = this user already earned for this
      # answer, so a repeat collides and awards nothing.
      add :source_key, :string, null: false
      # "ask" for the vertical slice; curation/streaks later.
      add :kind, :string, null: false
      add :xp, :integer, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Per-user dedupe: one grant per canonical answer per user, regardless of
    # cache hits or concurrent asks.
    create unique_index(:mastery_events, [:user_id, :source_key])
    create index(:mastery_events, [:user_id, :game_id])

    # Denormalized rollup: the mastery bar + which personas the user has unlocked
    # for this game. One row per (user, game).
    create table(:game_mastery) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :game_id, references(:games, on_delete: :delete_all), null: false
      add :xp, :integer, null: false, default: 0
      add :level, :integer, null: false, default: 0
      add :unlocked_voice_slugs, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:game_mastery, [:user_id, :game_id])

    # 0 = always available (current behavior for every persona). A positive value
    # gates the persona behind that per-game mastery level.
    alter table(:game_voices) do
      add :unlock_level, :integer, null: false, default: 0
    end
  end
end
