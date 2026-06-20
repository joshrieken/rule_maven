defmodule RuleMaven.Repo.Migrations.AddCheatsheetVersions do
  use Ecto.Migration

  def up do
    create table(:cheatsheet_versions) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :content, :text, null: false
      add :level, :text, null: false, default: "compact"
      add :active, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create index(:cheatsheet_versions, [:document_id])
    create index(:cheatsheet_versions, [:active])

    # Set first existing cheatsheet as active version
    execute """
    INSERT INTO cheatsheet_versions (document_id, content, level, active, inserted_at, updated_at)
    SELECT id, cheatsheet, 'compact', true, now(), now()
    FROM documents
    WHERE cheatsheet IS NOT NULL AND cheatsheet != ''
    """

    alter table(:documents) do
      remove :cheatsheet
    end
  end

  def down do
    alter table(:documents) do
      add :cheatsheet, :text
    end

    execute """
    UPDATE documents d
    SET cheatsheet = cv.content
    FROM cheatsheet_versions cv
    WHERE cv.document_id = d.id AND cv.active = true
    """

    drop table(:cheatsheet_versions)
  end
end
