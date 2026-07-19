defmodule RuleMaven.Repo.Migrations.CreateUserPageCoverages do
  use Ecto.Migration

  def change do
    create table(:user_page_coverages) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :page, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_page_coverages, [:user_id, :document_id, :page])
    create index(:user_page_coverages, [:user_id, :document_id])
  end
end
