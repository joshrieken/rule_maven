defmodule RuleMaven.Workers.MasteryBackfillWorker do
  @moduledoc """
  Applies XP banked while the `:mastery_levels` flag was off.

  Enqueued when an admin turns the flag on (or grants it to an actor / raises
  the rollout percentage), and run hourly as a backstop so percentage rollouts
  pick up newly-included users without an admin action. Cheap when there is
  nothing to do: the scan is a partial-index lookup over the unapplied tail,
  which is empty whenever the flag has been on all along.
  """
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 60]

  require Logger

  alias RuleMaven.Progress

  @impl Oban.Worker
  def perform(_job) do
    case Progress.backfill_pending() do
      %{events: 0} ->
        :ok

      %{users: users, events: events} ->
        Logger.info("MasteryBackfillWorker: applied #{events} banked events for #{users} users")

        :ok
    end
  end
end
