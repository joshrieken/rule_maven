defmodule RuleMaven.Repo.Migrations.ReplaceVisibilityWithPromoted do
  use Ecto.Migration

  # `questions_log.visibility` was a 2-value enum ('private'/'community') whose
  # name implied access but only meant "community-promoted." Replace it with a
  # boolean `promoted`, and re-point the generated audience/tier columns at it.
  # (house_rules.visibility is a separate column and is untouched.)
  def up do
    execute "DROP INDEX questions_log_audience_index"
    execute "ALTER TABLE questions_log DROP COLUMN tier"
    execute "ALTER TABLE questions_log DROP COLUMN audience"

    alter table(:questions_log) do
      add :promoted, :boolean, null: false, default: false
    end

    execute "UPDATE questions_log SET promoted = (visibility = 'community')"
    execute "ALTER TABLE questions_log DROP COLUMN visibility"

    execute """
    ALTER TABLE questions_log
      ADD COLUMN audience text GENERATED ALWAYS AS (
        CASE
          WHEN promoted OR (pooled AND browsable) THEN 'public'
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
          WHEN promoted THEN 'community'
          WHEN pooled AND browsable THEN 'unverified'
          ELSE NULL
        END
      ) STORED
    """

    create index(:questions_log, [:audience])
  end

  def down do
    execute "DROP INDEX questions_log_audience_index"
    execute "ALTER TABLE questions_log DROP COLUMN tier"
    execute "ALTER TABLE questions_log DROP COLUMN audience"

    alter table(:questions_log) do
      add :visibility, :string, null: false, default: "private"
    end

    execute "UPDATE questions_log SET visibility = CASE WHEN promoted THEN 'community' ELSE 'private' END"
    execute "ALTER TABLE questions_log DROP COLUMN promoted"

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
end
