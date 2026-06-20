defmodule RuleMaven.Games.Document do
  use Ecto.Schema
  import Ecto.Changeset

  schema "documents" do
    field :label, :string
    field :full_text, :string
    field :pdf_path, :string
    field :html_path, :string
    field :version, :integer, default: 1
    field :status, :string, default: "pending_review"
    field :file_hash, :string
    has_many :cheatsheet_versions, RuleMaven.CheatSheet.CheatSheetVersion
    belongs_to :game, RuleMaven.Games.Game
    belongs_to :reviewed_by, RuleMaven.Users.User

    field :reviewed_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :label,
      :full_text,
      :game_id,
      :pdf_path,
      :html_path,
      :version,
      :status,
      :file_hash,
      :reviewed_by_id,
      :reviewed_at
    ])
    |> validate_required([:label, :full_text, :game_id])
  end
end
