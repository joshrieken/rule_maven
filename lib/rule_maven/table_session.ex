defmodule RuleMaven.TableSession do
  @moduledoc """
  In-memory "at the table" session per {user, game}: which tool windows are
  open plus their volatile state, so navigating between game pages (separate
  LiveViews) doesn't close them. Deliberately ephemeral — ETS, lost on
  restart/deploy; durable per-tool data (checklist, score pad) already lives
  in browser localStorage.
  """
  use GenServer

  @table :rule_maven_table_sessions
  @ttl_ms :timer.hours(12)
  @sweep_ms :timer.hours(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Snapshot for this user+game; empty map when absent (or table not up)."
  def get(user_id, game_id) do
    case :ets.lookup(@table, {user_id, game_id}) do
      [{_key, snapshot, _at}] -> snapshot
      [] -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  @doc """
  Merge `snapshot` into this user+game's stored snapshot.

  Merge, not replace: each writer only knows about its own keys. `ToolHost`
  persists `Map.take(assigns, @session_keys)` on every tool event, which under
  replace semantics wiped `:active_group_id` (written by Show's group selector,
  a key ToolHost has never heard of) — so opening the crew Feed panel silently
  un-stuck the crew, and the next ask went private.
  """
  def put(user_id, game_id, snapshot) when is_map(snapshot) do
    GenServer.call(__MODULE__, {:put, user_id, game_id, snapshot})
  catch
    :exit, _ -> :ok
  end

  @doc "Drop entries idle longer than ttl_ms. Called on a timer; public for tests."
  def sweep(ttl_ms \\ @ttl_ms) do
    cutoff = System.monotonic_time(:millisecond) - ttl_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  # Serialized here rather than done inline in the caller: the merge is a
  # read-modify-write, and two sockets for the same {user, game} (two tabs, or
  # Show racing a tool event) could otherwise interleave read/read/write/write
  # and drop one side's keys — which is exactly the lost-`active_group_id` bug
  # the merge exists to prevent, just in a narrower window. Writes are rare
  # (one per tool event) so a single serializing process is not a bottleneck.
  @impl true
  def handle_call({:put, user_id, game_id, snapshot}, _from, state) do
    merged = Map.merge(get(user_id, game_id), snapshot)
    :ets.insert(@table, {{user_id, game_id}, merged, System.monotonic_time(:millisecond)})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end
end
