defmodule RuleMaven.Repo.Migrations.CreateDocumentPageCoverages do
  use Ecto.Migration

  def change do
    create table(:document_page_coverages) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :page, :integer, null: false
      add :first_covered_by_user_id, references(:users, on_delete: :nilify_all)
      add :first_question_log_id, references(:questions_log, on_delete: :nilify_all)
      add :first_covered_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:document_page_coverages, [:document_id, :page])
    create index(:document_page_coverages, [:first_covered_by_user_id])
  end
end
