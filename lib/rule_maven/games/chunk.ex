defmodule RuleMaven.Games.Chunk do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chunks" do
    field :chunk_index, :integer
    field :content, :string
    field :embedding, Pgvector.Ecto.Vector
    field :section_label, :string
    belongs_to :document, RuleMaven.Games.Document, foreign_key: :document_id

    timestamps(type: :utc_datetime)
  end

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [:document_id, :chunk_index, :content, :embedding, :section_label])
    |> validate_required([:document_id, :chunk_index, :content])
  end
end
