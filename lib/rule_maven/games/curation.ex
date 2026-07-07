defmodule RuleMaven.Games.Curation do
  @moduledoc """
  Curator incentives: settle votes against terminal trust events and derive
  voter rewards (curator points, bonus ask quota, badges).

  A vote settles at most once, when its row first reaches a terminal event:
  promotion/verify (`:confirmed` — upvotes were right) or moderation demotion
  (`:rejected` — downvotes were right). Only votes cast before the event
  settle, and author self-votes never do. `curator_points` is deliberately
  separate from `reputation`: it never feeds vote weight, so a vote ring's
  payoff is capped at cosmetic points and bounded bonus quota.
  """

  import Ecto.Query, warn: false

  alias RuleMaven.Games.{QuestionLog, QuestionVote}
  alias RuleMaven.Repo
  alias RuleMaven.Users.User

  @default_bonus_cap 20

  @doc """
  Settles all eligible, unsettled votes on a row. `:confirmed` marks upvotes
  correct; `:rejected` marks downvotes correct. Correct-settled voters gain
  one curator point each. Returns `{:ok, {correct_count, incorrect_count}}`.
  Idempotent: already-settled votes are never touched.
  """
  def settle_votes(%QuestionLog{} = q, outcome, event_at \\ NaiveDateTime.utc_now())
      when outcome in [:confirmed, :rejected] do
    correct_value = if outcome == :confirmed, do: "up", else: "down"
    author_id = q.user_id || -1
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    base =
      from v in QuestionVote,
        where:
          v.question_log_id == ^q.id and is_nil(v.settled_at) and
            v.user_id != ^author_id and v.weight > 0.0 and
            v.inserted_at <= ^event_at

    Repo.transaction(fn ->
      {_, correct_ids} =
        Repo.update_all(
          from(v in base, where: v.value == ^correct_value, select: v.user_id),
          set: [settled_at: now, settled_outcome: "correct"]
        )

      {incorrect_count, _} =
        Repo.update_all(
          from(v in base, where: v.value != ^correct_value),
          set: [settled_at: now, settled_outcome: "incorrect"]
        )

      correct_ids = correct_ids || []

      # One vote per (row, user), so a flat +1 per settled-correct voter.
      if correct_ids != [] do
        Repo.update_all(from(u in User, where: u.id in ^correct_ids),
          inc: [curator_points: 1]
        )
      end

      {length(correct_ids), incorrect_count}
    end)
  end

  def bonus_cap do
    case RuleMaven.Settings.get("curator_bonus_cap") do
      nil -> @default_bonus_cap
      "" -> @default_bonus_cap
      v ->
        case Integer.parse(to_string(v)) do
          {n, _} -> n
          :error -> @default_bonus_cap
        end
    end
  end

  @curator_threshold 10
  @sharp_eye_threshold 25
  @taste_maker_threshold 5

  @doc "Aggregate curator stats for the settings panel."
  def curator_stats(user_id) do
    {correct, incorrect} = settled_counts(user_id)
    points = Repo.one(from u in User, where: u.id == ^user_id, select: u.curator_points) || 0

    %{
      points: points,
      correct: correct,
      incorrect: incorrect,
      bonus_this_month: bonus_asks_this_month(user_id),
      badges: badges(user_id, correct)
    }
  end

  defp settled_counts(user_id) do
    rows =
      Repo.all(
        from v in QuestionVote,
          where: v.user_id == ^user_id and not is_nil(v.settled_outcome),
          group_by: v.settled_outcome,
          select: {v.settled_outcome, count()}
      )

    m = Map.new(rows)
    {Map.get(m, "correct", 0), Map.get(m, "incorrect", 0)}
  end

  @doc "Correct settles in the current UTC month, capped at `bonus_cap/0`."
  def bonus_asks_this_month(user_id) do
    month_start =
      Date.utc_today()
      |> Date.beginning_of_month()
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    n =
      Repo.one(
        from v in QuestionVote,
          where:
            v.user_id == ^user_id and v.settled_outcome == "correct" and
              v.settled_at >= ^month_start,
          select: count()
      ) || 0

    min(n, bonus_cap())
  end

  defp badges(user_id, correct) do
    base =
      [
        correct >= @curator_threshold && %{key: :curator, label: "Curator"},
        correct >= @sharp_eye_threshold && %{key: :sharp_eye, label: "Sharp Eye"}
      ]

    taste =
      taste_maker_count(user_id) >= @taste_maker_threshold &&
        %{key: :taste_maker, label: "Taste Maker"}

    Enum.filter([taste | base], & &1) |> Enum.reverse()
  end

  # Correct upvotes cast while the row still had fewer than `promotion_quorum`
  # earlier votes from other users — i.e. the voter spotted quality early.
  defp taste_maker_count(user_id) do
    quorum = RuleMaven.Games.Trust.promotion_quorum()

    Repo.one(
      from v in QuestionVote,
        where:
          v.user_id == ^user_id and v.settled_outcome == "correct" and v.value == "up" and
            fragment(
              "(SELECT COUNT(*) FROM question_votes v2 WHERE v2.question_log_id = ? AND v2.user_id != ? AND v2.inserted_at < ?) < ?",
              v.question_log_id,
              ^user_id,
              v.inserted_at,
              ^quorum
            ),
        select: count()
    ) || 0
  end

  @doc "Correct settles the user hasn't been shown yet (after curator_seen_at)."
  def unseen_correct_count(%User{id: id, curator_seen_at: seen_at}) do
    query =
      from v in QuestionVote,
        where: v.user_id == ^id and v.settled_outcome == "correct",
        select: count()

    query = if seen_at, do: from(v in query, where: v.settled_at > ^seen_at), else: query
    Repo.one(query) || 0
  end

  @doc "Advance the notice cursor to now."
  def mark_notices_seen(%User{id: id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.update_all(from(u in User, where: u.id == ^id), set: [curator_seen_at: now])
    :ok
  end
end
