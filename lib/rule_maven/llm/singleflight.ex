defmodule RuleMaven.LLM.Singleflight do
  @moduledoc """
  Collapses concurrent identical asks onto one answer call.

  Two players asking the same question at the same moment both miss the pool —
  an in-flight row is `pooled: false` with a `"Thinking..."` answer, so it is
  invisible to every cache tier. Both then pay a full answer call, and both
  `mark_pooled`, leaving two pooled rows for one canonical question. The
  duplicates are permanent, and every later pool query sorts over them.

  The first asker for a key becomes the *leader* and proceeds. Everyone else
  becomes a *follower* and blocks until the leader finishes, at which point the
  leader's answer is usually pooled and the follower's cache re-check hits it.
  A follower that still misses (leader errored, or its answer failed the
  citation gate) simply proceeds on its own — correctness never depends on the
  lock, only cost does.

  Scope is node-local, so a multi-node deploy collapses per node rather than
  globally; the fallback is exactly today's behavior (duplicate work, correct
  answers). A cross-node version would need the lock in Postgres, which would
  mean holding a transaction open across the whole LLM call.

  Leaders are monitored: a crashed or killed leader (`AskWorker.run_bounded/2`
  brutal-kills on timeout) releases the key and wakes its followers rather than
  stranding them until timeout.
  """
  use GenServer

  @table :llm_singleflight
  # Slightly above AskWorker's 180s hard cap: a follower should never outlive
  # the leader it is waiting on.
  @default_wait_ms 185_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Claims `key` for the calling process, or waits for the current leader.

  Returns `:leader` (caller must call `release/1` when done) or `:follower`
  (the leader has finished, crashed, or timed out — caller should re-check its
  caches and then proceed). Always returns; never raises.
  """
  def acquire(key, wait_ms \\ @default_wait_ms) do
    if table_ready?() do
      GenServer.call(__MODULE__, {:acquire, key}, :infinity)
      |> case do
        :leader ->
          :leader

        {:wait, ref} ->
          receive do
            {:singleflight_done, ^ref} -> :follower
          after
            wait_ms -> :follower
          end
      end
    else
      # No table (tests that don't start the app, or early boot) — everyone
      # leads. Degrades to pre-singleflight behavior.
      :leader
    end
  end

  @doc "Releases a key claimed by the calling process and wakes its followers."
  def release(key) do
    if table_ready?(), do: GenServer.cast(__MODULE__, {:release, key, self()})
    :ok
  end

  @doc """
  Runs `fun` under the key. Leaders execute it; followers execute `fun` too,
  but only after the leader finished — so a follower's cache re-check inside
  `fun` sees the leader's pooled answer.
  """
  def run(key, fun) do
    case acquire(key) do
      :leader ->
        try do
          fun.()
        after
          release(key)
        end

      :follower ->
        fun.()
    end
  end

  @doc "Builds a stable key from the ask's cache-identity fields."
  def ask_key(game_id, expansion_ids, match_text) do
    digest =
      :crypto.hash(:sha256, String.downcase(String.trim(to_string(match_text))))
      |> Base.encode16(case: :lower)

    {game_id, Enum.sort(expansion_ids), digest}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    # key => {leader_pid, [waiter_refs]}; monitors maps ref => key.
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:acquire, key}, {from_pid, _tag}, state) do
    case :ets.lookup(@table, key) do
      [] ->
        mref = Process.monitor(from_pid)
        :ets.insert(@table, {key, from_pid, []})
        {:reply, :leader, put_in(state.monitors[mref], key)}

      [{^key, leader_pid, waiters}] when leader_pid != from_pid ->
        ref = make_ref()
        :ets.insert(@table, {key, leader_pid, [{from_pid, ref} | waiters]})
        {:reply, {:wait, ref}, state}

      # Re-entrant: the leader asking for its own key again.
      [{^key, _leader_pid, _waiters}] ->
        {:reply, :leader, state}
    end
  end

  @impl true
  def handle_cast({:release, key, pid}, state) do
    {:noreply, do_release(key, pid, state)}
  end

  @impl true
  def handle_info({:DOWN, mref, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, mref) do
      {nil, _} -> {:noreply, state}
      {key, monitors} -> {:noreply, do_release(key, pid, %{state | monitors: monitors})}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Drops the key and wakes every waiter. Only the current leader may release —
  # a stale release (leader already replaced) must not free someone else's key.
  defp do_release(key, pid, state) do
    case :ets.lookup(@table, key) do
      [{^key, ^pid, waiters}] ->
        :ets.delete(@table, key)

        Enum.each(waiters, fn {waiter_pid, ref} -> send(waiter_pid, {:singleflight_done, ref}) end)

        demonitor_key(state, key)

      _ ->
        state
    end
  end

  defp demonitor_key(state, key) do
    case Enum.find(state.monitors, fn {_ref, k} -> k == key end) do
      {mref, _} ->
        Process.demonitor(mref, [:flush])
        %{state | monitors: Map.delete(state.monitors, mref)}

      nil ->
        state
    end
  end

  defp table_ready?, do: :ets.whereis(@table) != :undefined
end
