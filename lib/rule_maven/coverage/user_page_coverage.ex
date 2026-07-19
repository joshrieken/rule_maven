defmodule RuleMaven.Coverage.UserPageCoverage do
  @moduledoc """
  Tracks which document pages a given user has personally covered via
  answered questions — the storage foundation for per-player contribution
  incentives. One row per `(user_id, document_id, page)`, enforced by the
  unique index (not application code).
  """
  use Ecto.Schema

  schema "user_page_coverages" do
    field :page, :integer
    belongs_to :user, RuleMaven.Users.User
    belongs_to :document, RuleMaven.Games.Document

    timestamps(type: :utc_datetime)
  end
end
