defmodule RuleMaven.Repo.Migrations.AddMasteryEventAppliedAt do
  use Ecto.Migration

  def up do
    alter table(:mastery_events) do
      add :applied_at, :utc_datetime
    end

    # Every event written before the levelling feature flag existed was applied
    # to `game_mastery` the moment it was recorded.
    execute "UPDATE mastery_events SET applied_at = inserted_at"

    # Partial index: the backfill only ever scans the unapplied tail, which is
    # empty whenever the flag is on.
    create index(:mastery_events, [:user_id],
             where: "applied_at IS NULL",
             name: :mastery_events_pending_user_index
           )
  end

  def down do
    drop index(:mastery_events, [:user_id], name: :mastery_events_pending_user_index)

    alter table(:mastery_events) do
      remove :applied_at
    end
  end
end
