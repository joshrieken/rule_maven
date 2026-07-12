defmodule RuleMaven.Users.AuthCache do
  @moduledoc """
  Short-TTL in-memory cache of user rows for the per-event reauth checks,
  keyed by user id.

  `RuleMavenWeb.UserLiveAuth` re-verifies suspension/session/role standing
  before EVERY LiveView event so a revoked user can't keep firing events on a
  stale open socket — which meant one `Repo.get(User, id)` per keystroke,
  click, and form change for every connected user. The standing checks
  themselves (`suspended?/1`, `session_valid?/2`, `can?/2`) are pure functions
  of the struct, so caching the row for a few seconds keeps the security
  property while dropping almost all of those reads.

  Revocation stays effectively instant: every mutation that affects standing
  (suspend/unsuspend, force logout, role change, delete) calls `invalidate/1`,
  which drops the local entry synchronously and broadcasts
  `{:user_auth_invalidated, id}` on the `"users:auth"` PubSub topic so every
  node drops its copy. The 5s TTL is only the worst case for a missed
  invalidation (e.g. a row edited outside `RuleMaven.Users`).

  Disabled in test (`config :rule_maven, :cache_reauth, false`): the suite
  runs in the Ecto sandbox, and a globally-cached user written by one test
  would leak into the next.

  Backed by a public ETS table owned by this GenServer; `get/1` and `put/2`
  hit ETS directly. A periodic sweep drops expired entries so the table can't
  grow without bound.
  """
  use GenServer

  @table :user_auth_cache
  @topic "users:auth"
  @ttl_seconds 5
  @sweep_interval_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns `{:ok, user}` on a live hit, `:miss` otherwise."
  def get(user_id) do
    with true <- enabled?(),
         {user, stored_at} <- lookup(user_id),
         true <- now() - stored_at <= @ttl_seconds do
      {:ok, user}
    else
      _ -> :miss
    end
  end

  @doc "Stores `user` under their id. No-op until the table exists."
  def put(user_id, user) do
    if enabled?() and table_ready?() do
      :ets.insert(@table, {user_id, {user, now()}})
    end

    :ok
  end

  @doc """
  Drops `user_id` from the local table synchronously and broadcasts
  `{:user_auth_invalidated, user_id}` so every other node drops it too. Call
  after any successful write that affects login standing — the local delete
  must not wait on PubSub (delivery to self is async, and revocation must be
  visible to the very next event on this node).
  """
  def invalidate(user_id) do
    if table_ready?(), do: :ets.delete(@table, user_id)
    Phoenix.PubSub.broadcast(RuleMaven.PubSub, @topic, {:user_auth_invalidated, user_id})
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
  def handle_info({:user_auth_invalidated, user_id}, state) do
    :ets.delete(@table, user_id)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    cutoff = now() - @ttl_seconds
    # Match-delete every entry whose stored_at is older than the cutoff.
    :ets.select_delete(@table, [{{:_, {:_, :"$1"}}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp lookup(user_id) do
    if table_ready?() do
      case :ets.lookup(@table, user_id) do
        [{^user_id, value}] -> value
        [] -> nil
      end
    else
      nil
    end
  end

  defp enabled?, do: Application.get_env(:rule_maven, :cache_reauth, true)

  defp table_ready?, do: :ets.whereis(@table) != :undefined

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp now, do: System.system_time(:second)
end
