defmodule RuleMaven.SettingsCacheTest do
  # async: false — re-enables the (globally disabled in test) settings cache
  # via the app env and works against a shared named ETS table.
  use RuleMaven.DataCase, async: false

  alias RuleMaven.Repo
  alias RuleMaven.Settings
  alias RuleMaven.Settings.AppSetting
  alias RuleMaven.Settings.Cache

  setup do
    Application.put_env(:rule_maven, :cache_settings, true)
    Cache.flush()

    on_exit(fn ->
      Application.put_env(:rule_maven, :cache_settings, false)
      Cache.flush()
    end)

    :ok
  end

  test "get/1 serves repeat reads from the cache, not the DB" do
    {:ok, _} = Settings.put("cache_probe", "v1")
    assert Settings.get("cache_probe") == "v1"

    # Change the row behind the cache's back: a cached read must not see it.
    Repo.update_all(AppSetting, set: [value: "sneaky"])
    assert Settings.get("cache_probe") == "v1"

    # Busting brings the next read back to the DB.
    Cache.invalidate("cache_probe")
    assert Settings.get("cache_probe") == "sneaky"
  end

  test "put/2 busts the cache synchronously — put-then-get sees the new value" do
    {:ok, _} = Settings.put("sync_probe", "old")
    assert Settings.get("sync_probe") == "old"

    {:ok, _} = Settings.put("sync_probe", "new")
    assert Settings.get("sync_probe") == "new"
  end

  test "delete/1 busts the cache" do
    {:ok, _} = Settings.put("del_probe", "here")
    assert Settings.get("del_probe") == "here"

    {:ok, _} = Settings.delete("del_probe")
    assert Settings.get("del_probe") == nil
  end

  test "absent settings cache as nil and don't re-query until invalidated" do
    assert Settings.get("never_set") == nil

    # Insert the row behind the cache's back: the cached nil must hold...
    {:ok, _} = Repo.insert(AppSetting.changeset(%AppSetting{}, %{key: "never_set", value: "x"}))
    assert Settings.get("never_set") == nil

    # ...until the entry is invalidated.
    Cache.invalidate("never_set")
    assert Settings.get("never_set") == "x"
  end

  test "expired entries are a miss (TTL backstop)" do
    {:ok, _} = Settings.put("ttl_probe", "fresh")
    assert Settings.get("ttl_probe") == "fresh"

    # Backdate the entry past the TTL and change the row: the stale entry
    # must not be served.
    [{key, {value, _stored_at}}] = :ets.lookup(:settings_cache, "ttl_probe")
    :ets.insert(:settings_cache, {key, {value, System.system_time(:second) - 3600}})
    Repo.update_all(AppSetting, set: [value: "reloaded"])

    assert Settings.get("ttl_probe") == "reloaded"
  end

  test "pubsub broadcast drops the entry (multi-node invalidation path)" do
    {:ok, _} = Settings.put("bcast_probe", "v1")
    assert Settings.get("bcast_probe") == "v1"

    Phoenix.PubSub.broadcast(RuleMaven.PubSub, "settings", {:setting_changed, "bcast_probe"})
    # The cache GenServer processes the broadcast asynchronously; sync on it.
    _ = :sys.get_state(Cache)

    assert :ets.lookup(:settings_cache, "bcast_probe") == []
  end

  test "disabled cache is a passthrough" do
    Application.put_env(:rule_maven, :cache_settings, false)

    {:ok, _} = Settings.put("off_probe", "v1")
    assert Settings.get("off_probe") == "v1"
    assert :ets.lookup(:settings_cache, "off_probe") == []

    Repo.update_all(AppSetting, set: [value: "direct"])
    assert Settings.get("off_probe") == "direct"
  end
end
