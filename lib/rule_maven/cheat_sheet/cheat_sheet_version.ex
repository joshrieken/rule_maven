defmodule RuleMaven.CheatSheet.CheatSheetVersion do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cheatsheet_versions" do
    field :content, :string
    field :level, :string, default: "compact"
    field :active, :boolean, default: false
    belongs_to :document, RuleMaven.Games.Document

    timestamps(type: :utc_datetime)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [:content, :level, :active, :document_id])
    |> validate_required([:content, :document_id])
  end
end
