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
    # Community-promotion tier flag (was the `visibility` "private"/"community"
    # string — a name that implied access but only meant "promoted"). Access is
    # `audience`; this is one of its inputs.
    field :promoted, :boolean, default: false
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
    # the asker's wording or identity). Every row — solo or group — is written
    # false and is flipped true only by PublishCheckWorker (or an admin
    # force-publish override), which fails closed.
    field :browsable, :boolean, default: false
    # Set when a crew explicitly WITHDREW this row (group delete,
    # sole-owner account deletion). Durable, and deliberately never cleared:
    # turning contribution back on governs future asks, not ones already pulled
    # back. Withdrawal used to be INFERRED from `is_nil(group_id) and not
    # browsable`, which could not see a row retracted by a crew that still
    # exists, and which a re-pool racing the retraction erased outright.
    field :retracted_at, :utc_datetime_usec
    # Did the NORMALIZE step actually rewrite this question? Normalize is the step
    # that strips player names, so this is a privacy-critical fact — and it is
    # RECORDED, never inferred. Two gates used to reconstruct it by testing
    # `cleaned_question == question`, which can never be true: the stored text goes
    # through strip_game_name/2, whose last act appends a "?" if there isn't one.
    # A fallback is therefore "the raw question, plus a question mark", and both
    # gates waved it through as a genuine scrub.
    field :question_normalized, :boolean, default: false
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
    # DB-GENERATED, read-only. `audience` (:private/:crew/:public) is the single
    # source Games.reachable_by?/2 reads for "who may see the answer"; `tier`
    # (unverified/community/admin) is the FAQ badge. Postgres recomputes both
    # from {visibility, pooled, browsable, verified, group_id} on every write,
    # so they never desync. Never cast/write them — see audience/1 + tier/1 for
    # the Elixir mirror of the SQL expression.
    field :audience, :string, read_after_writes: true
    field :tier, :string, read_after_writes: true
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
  # A non-crew row starts unbrowsable exactly like a crew row and is cleared
  # by the same `PublishCheckWorker` gate; it was never treated differently
  # once this generalized.
  def listed_question(%{browsable: true, group_id: nil} = q), do: display_question(q)

  # `cleaned_question` is only a scrub if the scrub actually RAN. When normalize
  # 429s or its rewrite is rejected, `LLM.normalize_question/4` returns
  # `{:fallback, raw}` and AskWorker stores the asker's verbatim prose in the
  # column named `cleaned_question` — same column, no scrub, `question_normalized:
  # false`. PublishCheckWorker already refuses to publish such a row for exactly
  # this reason; falling back to the column here hands the same unscrubbed prose
  # to every admin list, and — via the `ilike` on `coalesce(canonical, cleaned)` —
  # to the admin search box as a substring oracle.
  def listed_question(%{question_normalized: true, cleaned_question: c} = q)
      when is_binary(c) do
    q.canonical_question || c
  end

  def listed_question(q), do: q.canonical_question || "(question withheld)"

  @doc """
  Did this row come out of a crew? The question is NOT "is `group_id` set" —
  that column is `on_delete: :nilify_all`, so a deleted crew's rows keep their
  unscreened text and lose the only marker saying where it came from.

  Two signals, either of which is proof of crew provenance, and the second
  survives the nilify:

    * `group_id` — the crew still exists.
    * `retracted_at` — only `Groups.retract_contributions/1` writes it, and it
      writes it to crew rows only. Set before the group is deleted, so it
      outlives the FK.

  `browsable == false` is NOT a signal here: every row, solo or group, is now
  born unbrowsable pending the publish screen (see `PublishCheckWorker`), so
  it no longer distinguishes crew provenance from "hasn't been screened yet."
  """
  def crew_origin?(%{group_id: gid}) when not is_nil(gid), do: true
  def crew_origin?(%{retracted_at: at}) when not is_nil(at), do: true
  def crew_origin?(_q), do: false

  @doc """
  Elixir mirror of the DB-generated `audience` column — who may see the ANSWER,
  independent of any viewer. Kept in exact lockstep with the SQL expression in
  `20260716000000_add_generated_audience_tier`; a test asserts stored == this
  for every row. Use the stored `q.audience` for live rows (indexed, SQL-usable);
  this function is for rows rebuilt off-DB (e.g. deleted-version snapshots).

    * `:public`  — visibility "community" OR (pooled AND screened/browsable)
    * `:crew`    — otherwise, while a group_id remains
    * `:private` — otherwise (owner only)
  """
  def audience(%{} = q) do
    cond do
      bool(q.promoted) or (bool(q.pooled) and bool(q.browsable)) -> :public
      not is_nil(Map.get(q, :group_id)) -> :crew
      true -> :private
    end
  end

  @doc """
  Elixir mirror of the DB-generated `tier` column — the FAQ verification badge,
  meaningful only when `audience/1` is `:public`. `nil` when not public.
  """
  def tier(%{} = q) do
    cond do
      bool(q.verified) -> :admin
      bool(q.promoted) -> :community
      bool(q.pooled) and bool(q.browsable) -> :unverified
      true -> nil
    end
  end

  defp bool(true), do: true
  defp bool(_), do: false

  @doc """
  Answer text safe to render on an admin/list surface — the companion to
  `listed_question/1`.

  Scrubbing the QUESTION and then painting the ANSWER beside it raw is no scrub
  at all: a crew answer restates the asker's private question ("Yes, Sarah may
  not palm a card…"), so it carries the same real names `listed_question/1`
  exists to withhold. Every admin panel that shows a Q&A pair leaked the wording
  back through the answer column one line below the withheld question.

  `browsable` is the gate, exactly as it is for the question: an answer shows
  only once the row is cleared for listing.

    * A non-crew row starts unbrowsable exactly like a crew row and is cleared
      by the same `PublishCheckWorker` gate; it was never treated differently
      once this generalized.
    * A crew row becomes `browsable` only when `PublishCheckWorker` clears it —
      and the screen it passed covers the answer (invariant A: a crew answer may
      leave the crew only once screened), so a cleared crew answer is safe.
    * An un-screened or retracted crew row (`browsable == false`, the nilify-safe
      marker) withholds the raw answer; a curator-written `canonical_answer` is
      reviewed text and may still show.
  """
  def listed_answer(%{browsable: true} = q), do: q.canonical_answer || q.answer
  def listed_answer(%{canonical_answer: a}) when is_binary(a) and a != "", do: a
  def listed_answer(_q), do: "(answer withheld)"

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
      :promoted,
      :parent_question_id,
      :refused,
      :blocked,
      :verdict,
      :cleaned_question,
      :raw_response,
      :followups,
      :also_asked,
      :question_normalized,
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
    |> validate_length(:question, max: 5_000)
    |> validate_length(:answer, max: 20_000)
    |> validate_length(:cited_passage, max: 20_000)
    |> foreign_key_constraint(:group_id)
    |> default_unbrowsable()
  end

  # Every row is born unbrowsable unless the caller says otherwise, so the
  # gate fails closed even if a future insert path forgets to pass `browsable`.
  # Was group-only; generalized so a solo row gets the identical treatment —
  # see PublishCheckWorker and AskWorker for the rest of the gate.
  #
  # INSERT only: on update, `browsable` is absent from most changesets (vote
  # counts, trust, staleness), and forcing it false there would silently undo
  # a publish check that had already passed.
  #
  # Keyed on the cast params, NOT on `get_change/2`: the field's schema default
  # is `false`, so a caller explicitly passing `browsable: true` produces no
  # *change* at all if the struct already defaults there, and a
  # `get_change == nil` test would read that as "caller said nothing" and slam
  # it shut regardless.
  defp default_unbrowsable(%Ecto.Changeset{data: %__MODULE__{id: nil}} = changeset) do
    explicit? =
      Map.has_key?(changeset.params || %{}, "browsable") or
        Map.has_key?(changeset.params || %{}, :browsable)

    if not explicit? do
      put_change(changeset, :browsable, false)
    else
      changeset
    end
  end

  defp default_unbrowsable(changeset), do: changeset
end
