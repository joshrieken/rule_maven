defmodule RuleMaven.Repo.Migrations.AddGeneratedAudienceTier do
  use Ecto.Migration

  # `audience` and `tier` are DB-computed views of the existing access fields,
  # not new state. STORED generated columns recompute on EVERY write to their
  # inputs — including `update_all` (which DirectPromotionWorker uses to set
  # `visibility`/`pooled`) — so they can never desync from the row they describe.
  #
  #   audience — who may see the ANSWER; the single source Games.reachable_by?/2
  #     reads. Mirrors the old predicate's public set exactly:
  #       public  = visibility 'community'  OR  (pooled AND browsable)
  #       crew    = otherwise, if the row still carries a group_id
  #       private = otherwise (owner only)
  #   tier — the FAQ verification badge, meaningful only when public.
  #
  # QuestionLog.audience/1 + tier/1 are the Elixir mirror of these expressions;
  # a test asserts stored == mirror for every row so SQL/Elixir drift fails loud.
  def up do
    execute """
    ALTER TABLE questions_log
      ADD COLUMN audience text GENERATED ALWAYS AS (
        CASE
          WHEN visibility = 'community' OR (pooled AND browsable) THEN 'public'
          WHEN group_id IS NOT NULL THEN 'crew'
          ELSE 'private'
        END
      ) STORED
    """

    execute """
    ALTER TABLE questions_log
      ADD COLUMN tier text GENERATED ALWAYS AS (
        CASE
          WHEN verified THEN 'admin'
          WHEN visibility = 'community' THEN 'community'
          WHEN pooled AND browsable THEN 'unverified'
          ELSE NULL
        END
      ) STORED
    """

    create index(:questions_log, [:audience])
  end

  def down do
    drop index(:questions_log, [:audience])
    execute "ALTER TABLE questions_log DROP COLUMN tier"
    execute "ALTER TABLE questions_log DROP COLUMN audience"
  end
end
