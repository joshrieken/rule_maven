defmodule RuleMaven.Embed.Cache do
  @moduledoc """
  In-memory cache of embedding vectors, keyed by a sha256 digest of the
  (trimmed, case-preserved) input text.

  Embeddings are a pure function of text for a given pinned model, so a
  repeated string always deserves the same vector. The ask pipeline now calls
  `embed/1` twice per normalize-miss (a hint lookup on the raw question, then
  again on the cleaned question) and suggested questions/re-asks send the same
  text through repeatedly — without a cache those repeats each re-pay the
  embedding API call. Caching the result is safe because the model is pinned
  (see `RuleMaven.Embed`'s dimension guard); nothing here changes what text
  maps to what vector, only whether we ask the API again for one already seen.

  Embeddings are case-sensitive (the model can and does embed "Foo" and "foo"
  differently), so the key is never downcased — only trimmed, since leading
  and trailing whitespace carries no semantic meaning callers rely on.

  Backed by a public ETS table owned by this GenServer; `get/1` and `put/2` hit
  ETS directly. A periodic sweep drops entries past their TTL so the table
  can't grow without bound.
  """
  use GenServer

  @table :embed_cache
  @ttl_seconds 86_400
  @sweep_interval_ms 3_600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns `{:ok, vec}` on a live hit, `:miss` otherwise."
  def get(text) when is_binary(text) do
    case lookup(key(text)) do
      {vec, stored_at} ->
        if now() - stored_at <= @ttl_seconds, do: {:ok, vec}, else: :miss

      nil ->
        :miss
    end
  end

  @doc "Stores `vec` for `text`. No-op until the table exists."
  def put(text, vec) when is_binary(text) do
    if table_ready?() do
      :ets.insert(@table, {key(text), {vec, now()}})
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

  defp key(text), do: :crypto.hash(:sha256, String.trim(text)) |> Base.encode16(case: :lower)

  defp table_ready?, do: :ets.whereis(@table) != :undefined

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp now, do: System.system_time(:second)
end
