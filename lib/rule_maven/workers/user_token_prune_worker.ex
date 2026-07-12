defmodule RuleMaven.Workers.UserTokenPruneWorker do
  @moduledoc """
  Daily maintenance for `user_tokens`. Auth tokens (magic link, password
  reset, email confirmation) are single-purpose rows that verification checks
  by age — an expired token is simply never matched, but its hash row lingers
  forever, growing the table and keeping stale `sent_to` addresses around.

  Deletes rows older than the longest validity window across all token
  contexts (email confirmation, 7 days — see `RuleMaven.Users.UserToken`)
  plus a safety margin, so nothing this worker removes could still verify.
  Cron-scheduled; safe to run repeatedly.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias RuleMaven.Repo
  alias RuleMaven.Users.UserToken

  # Longest validity across contexts is "confirm" at 7 days (UserToken's
  # @validity_seconds); the margin keeps this conservatively behind any future
  # small bump and makes clock skew irrelevant.
  @max_validity_days 7
  @safety_margin_days 7

  @impl Oban.Worker
  def perform(_job) do
    cutoff =
      DateTime.add(DateTime.utc_now(), -(@max_validity_days + @safety_margin_days), :day)

    Repo.delete_all(from t in UserToken, where: t.inserted_at < ^cutoff)
    :ok
  end
end
