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

    # The browse surfaces (unverified_pool_questions/2, DirectPromotionWorker)
    # filter on browsable alongside pooled.
    create index(:questions_log, [:game_id, :browsable])
  end
end
