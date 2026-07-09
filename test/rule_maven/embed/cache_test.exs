defmodule RuleMaven.Embed.CacheTest do
  # Table is shared/global (named ETS owned by the app-started GenServer), so
  # this can't run async alongside other tests that touch the same keys.
  use ExUnit.Case, async: false

  alias RuleMaven.Embed.Cache

  @table :embed_cache

  test "put/get round trip" do
    vec = [0.1, 0.2, 0.3]
    Cache.put("what is a rondel?", vec)

    assert Cache.get("what is a rondel?") == {:ok, vec}
  end

  test "miss on unknown key" do
    assert Cache.get("never seen this text before #{System.unique_integer()}") == :miss
  end

  test "distinct texts get distinct keys" do
    Cache.put("first question", [1.0])
    Cache.put("second question", [2.0])

    assert Cache.get("first question") == {:ok, [1.0]}
    assert Cache.get("second question") == {:ok, [2.0]}
  end

  test "case-sensitivity: different case is a different key" do
    Cache.put("What Is A Meeple", [9.0])

    assert Cache.get("What Is A Meeple") == {:ok, [9.0]}
    assert Cache.get("what is a meeple") == :miss
  end

  test "get/1 returns :miss for an expired entry" do
    text = "an old cached question"
    key = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
    stale_stored_at = System.system_time(:second) - 100_000

    :ets.insert(@table, {key, {[7.0], stale_stored_at}})

    assert Cache.get(text) == :miss
  end
end
