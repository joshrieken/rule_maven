defmodule RuleMaven.Moderation do
  @moduledoc """
  Read-side aggregates that surface misbehaving users and abuse patterns for the
  admin moderation dashboard. Every signal derives from existing tables
  (`questions_log`, `question_votes`, `users`) — no new data is collected here.

  Actions that act on these signals live in their owning contexts
  (`RuleMaven.Users` for suspension/reputation, `RuleMaven.Games.demote_user_answers/1`
  for pulling a user's answers).
  """

  import Ecto.Query, warn: false
  alias RuleMaven.Repo
  alias RuleMaven.Users
  alias RuleMaven.Games.{QuestionLog, QuestionVote}
  alias RuleMaven.Games.Trust

  @doc """
  Per-user moderation signals, highest risk first. Each row merges the user's
  account facts with counts over the answers they authored and the votes they
  cast. `risk` is a heuristic for sorting only — admins judge from the columns.
  """
  def user_signals do
    answer_stats = answer_stats_by_user()
    votes_cast = votes_cast_by_user()

    Users.list_users()
    |> Enum.map(fn u ->
      a = Map.get(answer_stats, u.id, empty_answer_stats())
      vc = Map.get(votes_cast, u.id, %{up: 0, down: 0})

      a
      |> Map.merge(%{
        user_id: u.id,
        username: u.username,
        email: u.email,
        role: u.role,
        reputation: u.reputation,
        monthly_quota: u.monthly_quota,
        confirmed: not is_nil(u.email_confirmed_at),
        suspended: not is_nil(u.suspended_at),
        is_admin: Users.can?(u, :admin),
        age_days: age_days(u.inserted_at),
        votes_up: vc.up,
        votes_down: vc.down
      })
      |> with_risk()
    end)
    |> Enum.sort_by(& &1.risk, :desc)
  end

  @doc """
  Voter→author pairs where one voter has cast at least `min` votes (default: the
  per-voter reputation cap) on a single author's answers. A high count that is
  almost entirely upvotes is the signature of a vote ring — the defense caps its
  reputation effect, but this surfaces the relationship for a human to judge.
  """
  def collusion_pairs(min \\ Trust.per_voter_rep_cap()) do
    rows =
      Repo.all(
        from v in QuestionVote,
          join: q in QuestionLog,
          on: q.id == v.question_log_id,
          where: not is_nil(q.user_id) and v.user_id != q.user_id,
          group_by: [v.user_id, q.user_id],
          having: count(v.id) >= ^min,
          select: %{
            voter_id: v.user_id,
            author_id: q.user_id,
            votes: count(v.id),
            ups: sum(fragment("CASE WHEN ? = 'up' THEN 1 ELSE 0 END", v.value))
          },
          order_by: [desc: count(v.id)]
      )

    names = username_map(rows)

    Enum.map(rows, fn r ->
      Map.merge(r, %{
        voter_name: Map.get(names, r.voter_id, "#" <> to_string(r.voter_id)),
        author_name: Map.get(names, r.author_id, "#" <> to_string(r.author_id))
      })
    end)
  end

  # --- internals -------------------------------------------------------------

  defp answer_stats_by_user do
    Repo.all(
      from q in QuestionLog,
        where: not is_nil(q.user_id),
        group_by: q.user_id,
        select: {
          q.user_id,
          %{
            total: count(q.id),
            refused: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", q.refused)),
            blocked: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", q.blocked)),
            needs_review: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", q.needs_review)),
            citation_invalid:
              sum(fragment("CASE WHEN NOT ? THEN 1 ELSE 0 END", q.citation_valid)),
            community: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", q.promoted))
          }
        }
    )
    |> Map.new()
  end

  defp votes_cast_by_user do
    # Self-votes are weight-0 "asker confirmed" markers, not community signal —
    # counting them here would flag every active asker as a heavy voter.
    Repo.all(
      from v in QuestionVote,
        join: q in QuestionLog,
        on: q.id == v.question_log_id,
        where: is_nil(q.user_id) or v.user_id != q.user_id,
        group_by: v.user_id,
        select: {
          v.user_id,
          %{
            up: sum(fragment("CASE WHEN ? = 'up' THEN 1 ELSE 0 END", v.value)),
            down: sum(fragment("CASE WHEN ? = 'down' THEN 1 ELSE 0 END", v.value))
          }
        }
    )
    |> Map.new()
  end

  defp username_map(rows) do
    ids =
      rows
      |> Enum.flat_map(&[&1.voter_id, &1.author_id])
      |> Enum.uniq()

    Repo.all(from u in RuleMaven.Users.User, where: u.id in ^ids, select: {u.id, u.username})
    |> Map.new()
  end

  defp empty_answer_stats do
    %{total: 0, refused: 0, blocked: 0, needs_review: 0, citation_invalid: 0, community: 0}
  end

  # Cheap heuristic for sort order. Blocked (injection attempts) weighs most;
  # new unconfirmed accounts that are already active get a bump.
  defp with_risk(s) do
    suspicious_new = if not s.confirmed and s.age_days < 7 and s.total > 5, do: 5, else: 0

    risk =
      s.blocked * 3 + s.refused + s.citation_invalid + s.needs_review * 2 + suspicious_new

    Map.put(s, :risk, risk)
  end

  defp age_days(nil), do: nil

  defp age_days(inserted_at) do
    DateTime.diff(DateTime.utc_now(), to_utc(inserted_at), :day)
  end

  defp to_utc(%DateTime{} = dt), do: dt
  defp to_utc(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
end
