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
    # May this row's QUESTION TEXT be listed to a non-asker? Distinct from
    # `pooled` (may its ANSWER serve the cross-user cache — which never exposes
    # the asker's wording or identity). Group rows are written false and are
    # flipped true only by PublishCheckWorker, which fails closed.
    field :browsable, :boolean, default: true
    # Set when a crew explicitly WITHDREW this row (contribute-off, group delete,
    # sole-owner account deletion). Durable, and deliberately never cleared:
    # turning contribution back on governs future asks, not ones already pulled
    # back. Withdrawal used to be INFERRED from `is_nil(group_id) and not
    # browsable`, which could not see a row retracted by a crew that still
    # exists, and which a re-pool racing the retraction erased outright.
    field :retracted_at, :utc_datetime_usec
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
    # Machine-readable failure classification for "⚠️ ..." error answers:
    # "empty" | "format" | "timeout" | "rate_limited" | "too_long" |
    # "unknown" | "paused". nil for normal answers. Drives the player-facing
    # retry affordance; rows with a kind set are excluded from the billable
    # quota count (the user shouldn't pay for our failures).
    field :error_kind, :string
    # Player-visible retries already consumed by this question. A retry
    # deletes + recreates the row, so resubmit carries the count forward.
    field :error_retries, :integer, default: 0
    # The exact (sorted) expansion-id set the answer was computed against.
    # [] = base game only. All cache tiers match on set equality so an answer
    # never crosses expansion configurations.
    field :expansion_ids, {:array, :integer}, default: []
    belongs_to :game, RuleMaven.Games.Game
    belongs_to :user, RuleMaven.Users.User
    belongs_to :document, RuleMaven.Games.Document
    belongs_to :parent_question, RuleMaven.Games.QuestionLog
    belongs_to :group, RuleMaven.Groups.Group

    timestamps(type: :utc_datetime)
  end

  @doc """
  User-facing question text. Prefers the admin-curated `canonical_question`,
  then the machine-normalized `cleaned_question`, falling back to the raw
  `question` as typed. The raw text is always preserved on the row.
  """
  def display_question(%__MODULE__{} = q),
    do: q.canonical_question || q.cleaned_question || q.question

  @doc """
  Question text safe to show to someone outside the asker's group.

  Same as `display_question/1` for an ordinary row, but a group row NEVER falls
  back to the raw `question` column — that fallback is exactly the asker's
  verbatim prose, and on the "ask exactly this" path it's the row's only text.

  Use this anywhere a row can reach a non-member: rendering, and — just as
  importantly — SEARCHING. Filtering a list on `question` while rendering
  `display_question/1` turns the search box into an oracle: the card appears and
  disappears on substrings of text the viewer is never shown, which is enough to
  reconstruct it a character at a time.

  The raw column is reachable only for a row that is BOTH cleared (`browsable`)
  and not crew-marked (`group_id` nil) — neither test alone is enough:

    * `browsable` alone: a crew row is browsable once the screen clears it, but
      what the screen cleared was the SCRUBBED text. Falling back to the raw
      column on a cleared crew row would publish the wording the scrub removed.
    * `group_id` alone: `questions_log.group_id` is `on_delete: :nilify_all`, so
      a deleted crew's rows keep their unscreened text while losing the marker
      that says where it came from. A group_id-keyed guard opens for exactly
      those rows — the trap that already bit `publishable?/1` and the
      SuggestionsWorker.
  """
  def listed_question(%{browsable: true, group_id: nil} = q), do: display_question(q)

  def listed_question(q),
    do: q.canonical_question || q.cleaned_question || "(question withheld)"

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
      :browsable,
      :pool_source_id,
      :needs_review,
      :stale,
      :favorited,
      :expansion_ids,
      :error_kind,
      :error_retries,
      :group_id
    ])
    |> validate_required([:question, :answer, :game_id])
    |> validate_inclusion(:visibility, ~w(private community))
    |> foreign_key_constraint(:group_id)
    |> default_group_unbrowsable()
  end

  # A group row is born unbrowsable unless the caller says otherwise, so the
  # gate fails closed even if a future insert path forgets to pass `browsable`.
  #
  # INSERT only: on update, `browsable` is absent from most changesets (vote
  # counts, trust, staleness), and forcing it false there would silently undo
  # a publish check that had already passed.
  #
  # Keyed on the cast params, NOT on `get_change/2`: the field's schema default
  # is `true`, so a caller explicitly passing `browsable: true` produces no
  # *change* at all, and a `get_change == nil` test would read that as "caller
  # said nothing" and slam it shut.
  defp default_group_unbrowsable(%Ecto.Changeset{data: %__MODULE__{id: nil}} = changeset) do
    explicit? =
      Map.has_key?(changeset.params || %{}, "browsable") or
        Map.has_key?(changeset.params || %{}, :browsable)

    if get_field(changeset, :group_id) && not explicit? do
      put_change(changeset, :browsable, false)
    else
      changeset
    end
  end

  defp default_group_unbrowsable(changeset), do: changeset
end
