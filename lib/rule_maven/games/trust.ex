defmodule RuleMaven.Games.Trust do
  @moduledoc """
  Reputation-weighted trust scoring for pooled Q&A.

  Two derived, denormalized signals:

    * `users.reputation` — earned from the net votes a user's authored answers
      receive, plus a bonus per answer promoted to the community pool. Drives how
      much each of that user's future votes counts.
    * `questions_log.trust_score` — the single ranking/promotion signal for a row:
      reputation-weighted net votes + a citation bonus, with `verified` acting as
      an admin override that floors the score at the top tier.

  `favorited` is a private bookmark and is deliberately excluded from trust.
  """

  import Ecto.Query, warn: false

  alias RuleMaven.Repo
  alias RuleMaven.Games.{QuestionLog, QuestionVote}
  alias RuleMaven.Users.User

  # Tunable defaults (overridable via RuleMaven.Settings, mirroring
  # pool_similarity_threshold). Values are stored as strings.
  @default_trusted_floor 3.0
  @default_promotion_floor 3.0
  @default_vote_weight_cap 4.0
  # Minimum distinct, eligible, non-author voters a row must have before it can
  # be promoted to the community pool. Stops a single (or single high-rep) vote
  # from auto-promoting an answer.
  @default_promotion_quorum 2
  # Accounts younger than this (hours) don't count toward a promotion quorum.
  # Raises the cost of sybil voting. 0 disables the age gate (set in prod).
  @default_vote_min_age_hours 0

  @citation_bonus 1.0
  @verified_floor 100.0
  @promotion_rep_bonus 5

  @doc """
  Vote weight for a user: new users weigh ~1.0, higher reputation weighs more
  (logarithmic, capped). Accepts a `%User{}` or a raw reputation integer.
  """
  def vote_weight(%User{reputation: rep}), do: vote_weight(rep)

  def vote_weight(rep) when is_integer(rep) and rep >= 0 do
    min(1.0 + :math.log(1 + rep), vote_weight_cap())
  end

  def vote_weight(_), do: 1.0

  @doc """
  Recomputes and persists `trust_score` for a question row from its weighted
  votes + citation bonus, with a pin override. Returns the new score.
  """
  def recompute_trust(%QuestionLog{} = q) do
    {up, down} =
      Repo.one(
        from v in QuestionVote,
          where: v.question_log_id == ^q.id,
          select: {
            sum(fragment("CASE WHEN ? = 'up' THEN ? ELSE 0 END", v.value, v.weight)),
            sum(fragment("CASE WHEN ? = 'down' THEN ? ELSE 0 END", v.value, v.weight))
          }
      ) || {nil, nil}

    net = (up || 0.0) - (down || 0.0)
    # Bonus only for a citation that's actually grounded in the source, not one
    # that's merely present (which a hallucination can fake).
    citation = if q.citation_valid, do: @citation_bonus, else: 0.0
    base = net + citation
    score = if q.verified, do: max(base, @verified_floor), else: base

    Repo.update_all(from(r in QuestionLog, where: r.id == ^q.id), set: [trust_score: score])
    score
  end

  @doc """
  Recomputes and persists `reputation` for a user: net (unweighted) votes across
  rows they authored + a bonus per row promoted to the community pool.
  """
  def recompute_reputation(user_id) when is_integer(user_id) do
    net =
      Repo.one(
        from q in QuestionLog,
          join: v in QuestionVote,
          on: v.question_log_id == q.id,
          where: q.user_id == ^user_id,
          select: sum(fragment("CASE WHEN ? = 'up' THEN 1 ELSE -1 END", v.value))
      ) || 0

    promotions =
      Repo.aggregate(
        from(q in QuestionLog, where: q.user_id == ^user_id and q.visibility == "community"),
        :count
      )

    rep = max(net + promotions * @promotion_rep_bonus, 0)
    Repo.update_all(from(u in User, where: u.id == ^user_id), set: [reputation: rep])
    rep
  end

  def recompute_reputation(_), do: 0

  @doc "True if the row carries a citation (passage or page)."
  def has_citation?(%QuestionLog{cited_passage: p, cited_page: pg}) do
    (is_binary(p) and String.trim(p) != "") or not is_nil(pg)
  end

  @doc """
  Count of distinct, promotion-eligible voters on a row, excluding the answer's
  author. A voter is eligible if their email is confirmed AND their account is at
  least `vote_min_age_hours` old. This is the quorum signal — votes still affect
  `trust_score`/labels even from ineligible voters, but only eligible distinct
  voters gate promotion.
  """
  def eligible_voter_count(%QuestionLog{id: id, user_id: author_id}),
    do: eligible_voter_count(id, author_id)

  def eligible_voter_count(question_log_id, author_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -round(vote_min_age_hours() * 3600), :second)
    exclude = author_id || -1

    Repo.one(
      from v in QuestionVote,
        join: u in User,
        on: u.id == v.user_id,
        where: v.question_log_id == ^question_log_id,
        where: v.user_id != ^exclude,
        where: not is_nil(u.email_confirmed_at),
        where: u.inserted_at <= ^cutoff,
        select: count(v.user_id, :distinct)
    ) || 0
  end

  # --- settings floors -------------------------------------------------------

  def trusted_floor, do: get_float("trusted_floor", @default_trusted_floor)
  def promotion_floor, do: get_float("promotion_floor", @default_promotion_floor)
  def vote_weight_cap, do: get_float("vote_weight_cap", @default_vote_weight_cap)
  def promotion_quorum, do: round(get_float("promotion_quorum", @default_promotion_quorum))
  def vote_min_age_hours, do: get_float("vote_min_account_age_hours", @default_vote_min_age_hours)

  defp get_float(key, default) do
    case RuleMaven.Settings.get(key) do
      nil ->
        default

      "" ->
        default

      v ->
        case Float.parse(to_string(v)),
          do: (
            {f, _} -> f
            :error -> default
          )
    end
  end
end
