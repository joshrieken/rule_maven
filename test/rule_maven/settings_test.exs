defmodule RuleMaven.SettingsTest do
  use RuleMaven.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
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

  test "asks_disabled_message falls back to a default, honors a custom value" do
    assert Settings.asks_disabled_message() =~ "paused"

    {:ok, _} = Settings.put("asks_disabled_message", "Back in 10.")
    assert Settings.asks_disabled_message() == "Back in 10."

    {:ok, _} = Settings.put("asks_disabled_message", "")
    assert Settings.asks_disabled_message() =~ "paused"
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
          Sandbox.allow(RuleMaven.Repo, parent, self())
          Settings.put(key, "v#{i}")
        end)
      end

    results = Task.await_many(tasks)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Settings.get(key) in Enum.map(1..10, &"v#{&1}")
  end

  test "with_prefix/1 and keys_with_prefix/1 match the prefix literally" do
    Settings.put("did_you_know_1", "a")
    Settings.put("did_you_know_2", "b")
    # "_" and "%" are LIKE wildcards; they must not match here.
    Settings.put("didXyou_know_3", "c")
    Settings.put("exp_sync:9", "1/2")

    assert Enum.sort(Settings.with_prefix("did_you_know_")) == [
             {"did_you_know_1", "a"},
             {"did_you_know_2", "b"}
           ]

    assert Enum.sort(Settings.keys_with_prefix("did_you_know_")) == [
             "did_you_know_1",
             "did_you_know_2"
           ]

    assert Settings.with_prefix("exp_sync:") == [{"exp_sync:9", "1/2"}]
    assert Settings.keys_with_prefix("%") == []
  end
end
