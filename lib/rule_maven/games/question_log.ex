defmodule RuleMaven.Games.QuestionLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "questions_log" do
    field :question, :string
    field :answer, :string
    field :cited_passage, :string
    field :verified, :boolean, default: false
    field :favorited, :boolean, default: false
    field :llm_provider, :string
    field :llm_model, :string
    field :cited_page, :integer
    field :question_embedding, Pgvector.Ecto.Vector
    field :source_chunk_ids, {:array, :integer}
    field :feedback, :string
    field :visibility, :string, default: "private"
    field :refused, :boolean, default: false
    field :blocked, :boolean, default: false
    field :verdict, :string
    field :cleaned_question, :string
    field :raw_response, :string
    field :followups, {:array, :string}, default: []
    field :also_asked, {:array, :string}, default: []
    field :canonical_question, :string
    field :canonical_answer, :string
    field :trust_score, :float, default: 0.0
    field :pooled, :boolean, default: false
    field :pool_source_id, :integer
    # Set when a rulebook content change may have invalidated a community answer.
    # The pool lookup skips flagged rows so they stop serving until re-approved.
    field :needs_review, :boolean, default: false
    belongs_to :game, RuleMaven.Games.Game
    belongs_to :user, RuleMaven.Users.User
    belongs_to :document, RuleMaven.Games.Document
    belongs_to :parent_question, RuleMaven.Games.QuestionLog

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(question_log, attrs) do
    question_log
    |> cast(attrs, [
      :question,
      :answer,
      :cited_passage,
      :game_id,
      :verified,
      :llm_provider,
      :llm_model,
      :user_id,
      :cited_page,
      :question_embedding,
      :source_chunk_ids,
      :feedback,
      :document_id,
      :visibility,
      :parent_question_id,
      :refused,
      :blocked,
      :verdict,
      :cleaned_question,
      :raw_response,
      :followups,
      :also_asked,
      :canonical_question,
      :canonical_answer,
      :trust_score,
      :pooled,
      :pool_source_id,
      :needs_review,
      :favorited
    ])
    |> validate_required([:question, :answer, :game_id])
  end
end
