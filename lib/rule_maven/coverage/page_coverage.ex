defmodule RuleMaven.Coverage.PageCoverage do
  @moduledoc """
  Tracks the first time each page of a document was covered by a question's
  answer — the storage foundation for the Rulebook Coverage Engine. One row
  per `(document_id, page)`, written once and never updated after the first
  hit (enforced by the unique index, not application code).
  """
  use Ecto.Schema

  schema "document_page_coverages" do
    field :page, :integer
    field :first_covered_at, :utc_datetime
    belongs_to :document, RuleMaven.Games.Document
    belongs_to :first_covered_by_user, RuleMaven.Users.User
    belongs_to :first_question_log, RuleMaven.Games.QuestionLog

    timestamps(type: :utc_datetime)
  end
end
