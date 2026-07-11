defmodule RuleMaven.Repo.Migrations.AddPublishGates do
  use Ecto.Migration

  def change do
    # May this row's QUESTION TEXT be shown to someone who is not the asker?
    # Orthogonal to `pooled` (servable by cache) and `visibility`. Default true
    # preserves every existing non-group row's behaviour exactly.
    alter table(:questions_log) do
      add :browsable, :boolean, null: false, default: true
    end

    alter table(:groups) do
      add :contribute_to_community, :boolean, null: false, default: true
    end

    # `default: true` above backfills every existing row, which is right for the
    # non-group ones (they were already browsable) and WRONG for the group rows
    # written by the persistent-groups feature, which shipped before this gate
    # existed: their text has never been screened. Close them explicitly.
    execute(
      "UPDATE questions_log SET browsable = false WHERE group_id IS NOT NULL",
      "UPDATE questions_log SET browsable = true WHERE group_id IS NOT NULL"
    )

    # The browse surfaces (unverified_pool_questions/2, DirectPromotionWorker)
    # filter on browsable alongside pooled.
    create index(:questions_log, [:game_id, :browsable])
  end
end
