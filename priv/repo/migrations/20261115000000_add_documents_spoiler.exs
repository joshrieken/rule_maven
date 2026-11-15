defmodule RuleMaven.Repo.Migrations.AddDocumentsSpoiler do
  use Ecto.Migration

  # A source whose content spoils campaign/unlock material (e.g. a FAQ's spoiler
  # section: locked classes, scenarios, items). Answers citing it are hidden
  # behind a warning until the player chooses to reveal them.
  def change do
    alter table(:documents) do
      add :spoiler, :boolean, null: false, default: false
    end
  end
end
