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
    field :cited_source, :string
    field :citations, {:array, :map}, default: []
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
    field :citation_valid, :boolean, default: false
    field :pooled, :boolean, default: false
    field :pool_source_id, :integer
    # Set when a rulebook content change may have invalidated a community answer.
    # The pool lookup skips flagged rows so they stop serving until re-approved.
    field :needs_review, :boolean, default: false
    # Set on EVERY row (any visibility) when a rulebook content change may have
    # invalidated it. Distinct from needs_review: needs_review also drives the
    # moderator abuse-risk score (moderation.ex), so it must stay scoped to
    # community/report-driven flags — stale is the content-invalidation signal
    # the same-user cache tiers (find_user_duplicate/find_user_similar) check.
    field :stale, :boolean, default: false
    # Times a pool/cache serve of this row was reported "not my question" by
    # the asker (Games.record_pool_mismatch/1). Tuning signal for the pool
    # matching thresholds — never shown to users, never affects serving.
    field :mismatch_count, :integer, default: 0
    # The exact (sorted) expansion-id set the answer was computed against.
    # [] = base game only. All cache tiers match on set equality so an answer
    # never crosses expansion configurations.
    field :expansion_ids, {:array, :integer}, default: []
    belongs_to :game, RuleMaven.Games.Game
    belongs_to :user, RuleMaven.Users.User
    belongs_to :document, RuleMaven.Games.Document
    belongs_to :parent_question, RuleMaven.Games.QuestionLog

    timestamps(type: :utc_datetime)
  end

  @doc """
  User-facing question text. Prefers the admin-curated `canonical_question`,
  then the machine-normalized `cleaned_question`, falling back to the raw
  `question` as typed. The raw text is always preserved on the row.
  """
  def display_question(%__MODULE__{} = q),
    do: q.canonical_question || q.cleaned_question || q.question

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
      :cited_source,
      :citations,
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
      :citation_valid,
      :pooled,
      :pool_source_id,
      :needs_review,
      :stale,
      :favorited,
      :expansion_ids
    ])
    |> validate_required([:question, :answer, :game_id])
  end
end
