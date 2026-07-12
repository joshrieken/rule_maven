defmodule RuleMaven.Settings.Cache do
  @moduledoc """
  In-memory cache of app settings, keyed by the setting key string.

  `Settings.get/1` was a bare `Repo.get` and the hot paths (the ask pipeline,
  mail, kill switches) read dozens of settings per request — each one a
  round trip for a value that changes only when an admin edits it. This cache
  serves those reads from ETS.

  Absent settings are cached too (as a `nil` value): many settings are
  optional, so a miss would otherwise re-query on every read forever.

  Coherence is invalidation-first: every write in `RuleMaven.Settings` busts
  the local entry synchronously (so a put-then-get in the same process sees
  the new value) and broadcasts `{:setting_changed, key}` on the `"settings"`
  PubSub topic so every node's cache drops its copy. A short TTL is kept as a
  belt-and-braces backstop against a missed invalidation, with a periodic
  sweep so the table can't grow without bound.

  Disabled in test (`config :rule_maven, :cache_settings, false`): the suite
  runs in the Ecto sandbox, and a globally-cached value written by one test
  would leak into the next — same reason `fun_with_flags`' cache is off there.

  Backed by a public ETS table owned by this GenServer; `get/1` and `put/2`
  hit ETS directly.
  """
  use GenServer

  @table :settings_cache
  @topic "settings"
  @ttl_seconds 60
  @sweep_interval_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns `{:ok, value}` on a live hit (`value` may be nil), `:miss` otherwise."
  def get(key) do
    with true <- enabled?(),
         {value, stored_at} <- lookup(key),
         true <- now() - stored_at <= @ttl_seconds do
      {:ok, value}
    else
      _ -> :miss
    end
  end

  @doc "Stores `value` (nil meaning: setting is absent) for `key`. No-op until the table exists."
  def put(key, value) do
    if enabled?() and table_ready?() do
      :ets.insert(@table, {key, {value, now()}})
    end

    :ok
  end

  @doc """
  Drops `key` from the local table synchronously and broadcasts
  `{:setting_changed, key}` so every other node drops it too. Call after any
  successful settings write — the local delete must not wait on PubSub
  (delivery to self is async, and the writer may read back immediately).
  """
  def invalidate(key) do
    if table_ready?(), do: :ets.delete(@table, key)
    Phoenix.PubSub.broadcast(RuleMaven.PubSub, @topic, {:setting_changed, key})
    :ok
  end

  @doc "Empties the table. Test helper."
  def flush do
    if table_ready?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(RuleMaven.PubSub, @topic)
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:setting_changed, key}, state) do
    :ets.delete(@table, key)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    cutoff = now() - @ttl_seconds
    # Match-delete every entry whose stored_at is older than the cutoff.
    :ets.select_delete(@table, [{{:_, {:_, :"$1"}}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp lookup(key) do
    if table_ready?() do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> value
        [] -> nil
      end
    else
      nil
    end
  end

  defp enabled?, do: Application.get_env(:rule_maven, :cache_settings, true)

  defp table_ready?, do: :ets.whereis(@table) != :undefined

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp now, do: System.system_time(:second)
end
