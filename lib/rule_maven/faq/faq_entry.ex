defmodule RuleMaven.Faq.FaqEntry do
  use Ecto.Schema
  import Ecto.Changeset

  schema "faq_entries" do
    field :canonical_question, :string
    field :canonical_answer, :string
    field :question_embedding, Pgvector.Ecto.Vector
    field :source_qa_ids, {:array, :integer}
    field :status, :string, default: "draft"
    field :auto_approved, :boolean, default: false
    field :auto_approve_reason, :string
    field :approved_at, :utc_datetime
    belongs_to :game, RuleMaven.Games.Game
    belongs_to :approved_by, RuleMaven.Users.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(faq_entry, attrs) do
    faq_entry
    |> cast(attrs, [
      :canonical_question,
      :canonical_answer,
      :question_embedding,
      :source_qa_ids,
      :status,
      :auto_approved,
      :auto_approve_reason,
      :approved_at,
      :game_id,
      :approved_by_id
    ])
    |> validate_required([:canonical_question, :canonical_answer, :game_id, :source_qa_ids])
  end
end
