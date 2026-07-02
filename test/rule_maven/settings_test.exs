defmodule RuleMaven.SettingsTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.Settings

  test "put inserts a new key" do
    assert {:ok, _} = Settings.put("fresh_key", "v1")
    assert Settings.get("fresh_key") == "v1"
  end

  test "put overwrites an existing key" do
    {:ok, _} = Settings.put("dup_key", "v1")
    {:ok, _} = Settings.put("dup_key", "v2")
    assert Settings.get("dup_key") == "v2"
  end

  test "concurrent puts to the same key don't crash and last write is durably readable" do
    # Two processes racing to insert the same key would hit the unique_constraint
    # under the old get-then-insert_or_update implementation (both see `nil` from
    # Repo.get, both attempt an insert, second one fails). The upsert must
    # tolerate this without raising.
    key = "race_key"
    parent = self()

    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(RuleMaven.Repo, parent, self())
          Settings.put(key, "v#{i}")
        end)
      end

    results = Task.await_many(tasks)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Settings.get(key) in Enum.map(1..10, &"v#{&1}")
  end
end
