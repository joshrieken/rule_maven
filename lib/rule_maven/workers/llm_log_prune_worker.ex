defmodule RuleMaven.Workers.LlmLogPruneWorker do
  @moduledoc """
  Daily maintenance for `llm_logs`. Each row carries a multi-KB `detail` JSONB
  (input/output previews for the admin trace panel) that nobody reads once a
  question is a month old — but the token/cost columns feed cost reporting
  forever. So this strips `detail` (sets it to NULL) on rows older than the
  30-day retention window and deletes nothing. The trace panel already treats
  a nil `detail` as an empty map. Cron-scheduled; safe to run repeatedly.

  Rows are stripped in batches of 5000 so a large backlog never holds one
  long-running UPDATE; a per-run pass cap bounds runtime, and the next daily
  run picks up whatever is left.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias RuleMaven.LLM.Log
  alias RuleMaven.Repo

  # Keep one month of trace detail; token/cost columns are kept forever.
  @retention_days 30
  @batch_size 5000
  # Bound a single run even against a huge backlog (200 * 5000 = 1M rows).
  @max_passes 200

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days, :day)
    strip_details(cutoff, @max_passes)
    :ok
  end

  defp strip_details(_cutoff, 0), do: :ok

  defp strip_details(cutoff, passes_left) do
    ids =
      Repo.all(
        from l in Log,
          where: l.inserted_at < ^cutoff and not is_nil(l.detail),
          select: l.id,
          limit: @batch_size
      )

    case ids do
      [] ->
        :ok

      ids ->
        Repo.update_all(from(l in Log, where: l.id in ^ids), set: [detail: nil])
        strip_details(cutoff, passes_left - 1)
    end
  end
end
