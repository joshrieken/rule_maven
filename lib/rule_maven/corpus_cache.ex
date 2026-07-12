defmodule RuleMaven.CorpusCache do
  @moduledoc """
  In-memory cache of per-game-set corpus sizes ({chunk count, content chars}),
  keyed by the SORTED list of game ids (base + expansions in any combination).

  `maybe_expand_to_small_corpus/3` in `RuleMaven.Games` runs a count+sum
  aggregate over every published chunk for the game set on EVERY fresh ask,
  for a value that only changes when a document is published/edited/deleted.
  This cache serves those reads from ETS.

  Coherence is invalidation-first: every rulebook content change funnels
  through `Games.invalidate_pool/1`, which calls `invalidate_all/0` — the
  table is dropped whole (it is tiny, and keys are game-id SETS, so targeted
  invalidation would have to enumerate every set containing the changed game)
  and `:corpus_cache_flushed` is broadcast on the `"corpus_cache"` PubSub
  topic so every node's cache drops its copy too. A short TTL is kept as a
  belt-and-braces backstop against a missed invalidation, with a periodic
  sweep so the table can't grow without bound.

  Disabled in test (`config :rule_maven, :cache_corpus, false`): the suite
  runs in the Ecto sandbox, and a globally-cached value written by one test
  would leak into the next — same reason `Settings.Cache` is off there.

  Backed by a public ETS table owned by this GenServer; `get/1` and `put/2`
  hit ETS directly.
  """
  use GenServer

  @table :corpus_cache
  @topic "corpus_cache"
  @ttl_seconds 300
  @sweep_interval_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns `{:ok, {count, chars}}` on a live hit, `:miss` otherwise."
  def get(key) do
    with true <- enabled?(),
         {value, stored_at} <- lookup(key),
         true <- now() - stored_at <= @ttl_seconds do
      {:ok, value}
    else
      _ -> :miss
    end
  end

  @doc "Stores `{count, chars}` for `key`. No-op until the table exists."
  def put(key, value) do
    if enabled?() and table_ready?() do
      :ets.insert(@table, {key, {value, now()}})
    end

    :ok
  end

  @doc """
  Empties the table synchronously and broadcasts `:corpus_cache_flushed` so
  every other node empties its copy too. Called from `Games.invalidate_pool/1`
  — the local flush must not wait on PubSub (delivery to self is async, and
  the writer's next ask may read back immediately).
  """
  def invalidate_all do
    if table_ready?(), do: :ets.delete_all_objects(@table)
    Phoenix.PubSub.broadcast(RuleMaven.PubSub, @topic, :corpus_cache_flushed)
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
  def handle_info(:corpus_cache_flushed, state) do
    :ets.delete_all_objects(@table)
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

  defp enabled?, do: Application.get_env(:rule_maven, :cache_corpus, true)

  defp table_ready?, do: :ets.whereis(@table) != :undefined

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp now, do: System.system_time(:second)
end
