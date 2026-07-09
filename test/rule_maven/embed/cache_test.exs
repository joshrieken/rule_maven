defmodule RuleMaven.Embed.CacheTest do
  # Table is shared/global (named ETS owned by the app-started GenServer), so
  # this can't run async alongside other tests that touch the same keys.
  use ExUnit.Case, async: false

  alias RuleMaven.Embed.Cache

  @table :embed_cache
  @model "openai/text-embedding-3-small"

  test "put/get round trip" do
    vec = [0.1, 0.2, 0.3]
    Cache.put(@model, "what is a rondel?", vec)

    assert Cache.get(@model, "what is a rondel?") == {:ok, vec}
  end

  test "miss on unknown key" do
    assert Cache.get(@model, "never seen this text before #{System.unique_integer()}") == :miss
  end

  test "distinct texts get distinct keys" do
    Cache.put(@model, "first question", [1.0])
    Cache.put(@model, "second question", [2.0])

    assert Cache.get(@model, "first question") == {:ok, [1.0]}
    assert Cache.get(@model, "second question") == {:ok, [2.0]}
  end

  test "case-sensitivity: different case is a different key" do
    Cache.put(@model, "What Is A Meeple", [9.0])

    assert Cache.get(@model, "What Is A Meeple") == {:ok, [9.0]}
    assert Cache.get(@model, "what is a meeple") == :miss
  end

  test "a vector cached under one model is never served for another" do
    # embedding_model is a live setting, and two of the offered models share
    # 768 dimensions — so the dimension guard would not catch a cross-model
    # vector being compared against pgvector rows from the other model.
    Cache.put(@model, "how many players?", [1.0, 2.0])

    assert Cache.get("nomic-embed-text", "how many players?") == :miss
    assert Cache.get(@model, "how many players?") == {:ok, [1.0, 2.0]}
  end

  test "get/2 returns :miss for an expired entry" do
    text = "an old cached question"
    key = :crypto.hash(:sha256, [@model, 0, text]) |> Base.encode16(case: :lower)
    stale_stored_at = System.system_time(:second) - 100_000

    :ets.insert(@table, {key, {[7.0], stale_stored_at}})

    assert Cache.get(@model, text) == :miss
  end
end
