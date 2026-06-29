defmodule RuleMaven.Games.ReextractLog do
  @moduledoc """
  One line of a single-page re-extraction progress log, scoped to a source
  document. Append-only (one INSERT per stage), so concurrent jobs can write
  without a read-modify-write race. Durable (Postgres) so the log survives a
  browser refresh and an Oban/server restart; cleared at the start of each
  re-extract run for the document.
  """
  use Ecto.Schema

  schema "reextract_logs" do
    field :text, :string
    field :kind, :string, default: "info"
    belongs_to :document, RuleMaven.Games.Document

    timestamps(updated_at: false)
  end
end
