defmodule RuleMaven.Repo.Migrations.DropCheatPdfPath do
  use Ecto.Migration

  def up do
    alter table(:games) do
      remove :cheat_pdf_path
    end
  end

  def down do
    alter table(:games) do
      add :cheat_pdf_path, :string
    end
  end
end
