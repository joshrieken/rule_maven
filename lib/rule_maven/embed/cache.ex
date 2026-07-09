defmodule RuleMaven.Embed.Cache do
  @moduledoc """
  In-memory cache of embedding vectors, keyed by a sha256 digest of the
  embedding model name plus the (trimmed, case-preserved) input text.

  Embeddings are a pure function of text *for a given model*, so a repeated
  string always deserves the same vector. The ask pipeline calls `embed/1`
  twice per normalize-miss (a hint lookup on the raw question, then again on
  the cleaned question) and suggested questions/re-asks send the same text
  through repeatedly — without a cache those repeats each re-pay the embedding
  API call.

  The model is part of the key because it is NOT pinned: `embedding_model` is a
  live Settings value with an admin dropdown. `RuleMaven.Embed`'s only guard is
  a dimension check, and two of the offered models are both 768-dim — so a
  text-only key would serve a vector produced by the previous model against
  pgvector rows written by the new one, with no error and no dimension
  mismatch. (Switching models still requires re-embedding every stored vector;
  this key only stops the cache from *adding* incoherence.)

  Embeddings are case-sensitive (the model can and does embed "Foo" and "foo"
  differently), so the key is never downcased — only trimmed, since leading
  and trailing whitespace carries no semantic meaning callers rely on.

  Backed by a public ETS table owned by this GenServer; `get/2` and `put/3` hit
  ETS directly. A periodic sweep drops entries past their TTL so the table
  can't grow without bound.
  """
  use GenServer

  @table :embed_cache
  @ttl_seconds 86_400
  @sweep_interval_ms 3_600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns `{:ok, vec}` on a live hit for this model, `:miss` otherwise."
  def get(model, text) when is_binary(model) and is_binary(text) do
    case lookup(key(model, text)) do
      {vec, stored_at} ->
        if now() - stored_at <= @ttl_seconds, do: {:ok, vec}, else: :miss

      nil ->
        :miss
    end
  end

  @doc "Stores `vec` for `{model, text}`. No-op until the table exists."
  def put(model, text, vec) when is_binary(model) and is_binary(text) do
    if table_ready?() do
      :ets.insert(@table, {key(model, text), {vec, now()}})
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

  # NUL separator so no model/text pair can collide with another by concatenation.
  defp key(model, text) do
    :crypto.hash(:sha256, [model, 0, String.trim(text)]) |> Base.encode16(case: :lower)
  end

  defp table_ready?, do: :ets.whereis(@table) != :undefined

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp now, do: System.system_time(:second)
end
