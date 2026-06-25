defmodule RuleMaven.Repo.Migrations.AddExtractionMetadataToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :content_type, :string
      add :file_size, :integer
      add :page_count, :integer
      add :printed_offset, :integer
      add :from_ocr, :boolean, default: false, null: false
      add :extracted_at, :utc_datetime
    end
  end
end
