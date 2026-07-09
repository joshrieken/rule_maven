defmodule RuleMaven.LLM.NormalizeCache do
  @moduledoc """
  In-memory cache of normalized questions, keyed per `{game_id, downcased_raw}`.

  Question normalization runs a (cheap) LLM call on every ask to rewrite the
  question into a stable canonical form before it drives the pool lookup and
  retrieval. Repeated phrasings — common ones, suggested questions, a user
  re-asking the same text — would otherwise pay that call every time. The
  rewrite is deterministic for a given raw string, so caching it is safe.

  Only context-free questions are cached (followups resolve against the recent
  conversation, so their normalization is not a pure function of the raw text —
  the caller skips the cache for those).

  Backed by a public ETS table owned by this GenServer; `get/1` and `put/2` hit
  ETS directly. A periodic sweep drops entries past their TTL so the table can't
  grow without bound.
  """
  use GenServer

  @table :llm_normalize_cache
  @ttl_seconds 86_400
  @sweep_interval_ms 3_600_000

  # Short TTL for a normalize FALLBACK (the raw question, kept because the call
  # errored or the rewrite was rejected). Caching those for the full day pinned
  # a bad canonical form for every user of the game; not caching them at all
  # re-paid the call on every ask when the rejection was deterministic. A few
  # minutes absorbs the repeat traffic without outliving a transient blip.
  @fallback_ttl_seconds 600

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns `{:ok, cleaned}` on a live hit, `:miss` otherwise."
  def get(key) do
    case lookup(key) do
      {cleaned, stored_at, ttl} ->
        if now() - stored_at <= ttl, do: {:ok, cleaned}, else: :miss

      nil ->
        :miss
    end
  end

  @doc "Stores `cleaned` for `key` under the full TTL. No-op until the table exists."
  def put(key, cleaned), do: put(key, cleaned, @ttl_seconds)

  @doc "Stores a normalize fallback under a short TTL."
  def put_fallback(key, raw), do: put(key, raw, @fallback_ttl_seconds)

  def put(key, cleaned, ttl) do
    if table_ready?() do
      :ets.insert(@table, {key, {cleaned, now(), ttl}})
    end

    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now()
    # Match-delete every entry whose age has passed its own TTL.
    :ets.select_delete(@table, [
      {{:_, {:_, :"$1", :"$2"}}, [{:>, {:-, now, :"$1"}, :"$2"}], [true]}
    ])

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

  defp table_ready?, do: :ets.whereis(@table) != :undefined

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp now, do: System.system_time(:second)
end
