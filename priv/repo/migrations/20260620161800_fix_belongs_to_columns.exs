defmodule RuleMaven.Repo.Migrations.FixBelongsToColumns do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE documents RENAME COLUMN reviewed_by TO reviewed_by_id"
    execute "ALTER TABLE faq_entries RENAME COLUMN approved_by TO approved_by_id"
  end

  def down do
    execute "ALTER TABLE documents RENAME COLUMN reviewed_by_id TO reviewed_by"
    execute "ALTER TABLE faq_entries RENAME COLUMN approved_by_id TO approved_by"
  end
end
