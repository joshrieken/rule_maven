defmodule RuleMaven.HealthStats do
  @moduledoc """
  Shared, ETS-cached bundle of the System Health dashboard's stats.

  `AdminLive.Health` refreshes on a per-socket 15s timer, and each tick used
  to run the full query bundle — an `oban_jobs` group-by over ALL states
  (including the huge `completed` set), a users count, today's LLM cost, and
  the 24h error rate — once per connected admin socket. With N admins on the
  page that was N copies of the same expensive scan every 15 seconds.

  `get/0` serves the whole bundle from ETS and recomputes at most once per
  #{15}s window, no matter how many sockets are ticking. Staleness is checked
  against `computed_at`; a stale/missing entry is recomputed inline in the
  CALLER (not the GenServer), so a slow query never blocks other ETS readers —
  at worst two concurrent callers double-compute, which is harmless.

  Backed by a public ETS table owned by this GenServer (same shape as
  `RuleMaven.Settings.Cache`); the GenServer only owns the table's lifetime.
  If the table isn't up yet (e.g. a direct call in tests without supervision),
  `get/0` computes fresh and skips caching.

  Disabled in test (`config :rule_maven, :cache_health_stats, false`): the
  suite runs in the Ecto sandbox, and globally-cached counts computed by one
  test would leak into the next — same reason `Settings.Cache` is off there.
  """
  use GenServer

  import Ecto.Query

  alias RuleMaven.{LLM, Repo, Users}

  @table :health_stats_cache
  @key :stats
  @ttl_seconds 15

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the stats map: `%{oban: ..., err: ..., cost_today: ..., total_users:
  ..., computed_at: DateTime}`. Served from ETS when computed within the last
  #{@ttl_seconds}s; otherwise recomputed inline and cached.
  """
  def get do
    case fresh_lookup() do
      {:ok, stats} -> stats
      :miss -> compute_and_store()
    end
  end

  @doc "Empties the cache. Test helper."
  def flush do
    if table_ready?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  defp fresh_lookup do
    with true <- enabled?(),
         true <- table_ready?(),
         [{@key, {stats, stored_at}}] <- :ets.lookup(@table, @key),
         true <- now() - stored_at <= @ttl_seconds do
      {:ok, stats}
    else
      _ -> :miss
    end
  end

  defp compute_and_store do
    stats = compute()

    if enabled?() and table_ready?() do
      :ets.insert(@table, {@key, {stats, now()}})
    end

    stats
  end

  defp compute do
    %{
      oban: oban_counts(),
      err: LLM.error_rate(24),
      cost_today: LLM.cost_today(),
      total_users: Repo.aggregate(Users.User, :count),
      computed_at: DateTime.utc_now()
    }
  end

  # Oban job counts by state (overall) and per-queue for the "live" states.
  defp oban_counts do
    by_state =
      Repo.all(from j in "oban_jobs", group_by: j.state, select: {j.state, count(j.id)})
      |> Map.new()

    per_queue =
      Repo.all(
        from j in "oban_jobs",
          where: j.state in ["available", "executing", "retryable", "scheduled"],
          group_by: [j.queue, j.state],
          select: {j.queue, j.state, count(j.id)}
      )
      |> Enum.group_by(fn {q, _, _} -> q end, fn {_, s, c} -> {s, c} end)
      |> Enum.map(fn {q, states} -> {q, Map.new(states)} end)
      |> Enum.sort_by(fn {q, _} -> q end)

    %{by_state: by_state, per_queue: per_queue}
  end

  defp enabled?, do: Application.get_env(:rule_maven, :cache_health_stats, true)

  defp table_ready?, do: :ets.whereis(@table) != :undefined

  defp now, do: System.system_time(:second)
end
