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
end
