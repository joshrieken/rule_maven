defmodule RuleMaven.UsersAuthCacheTest do
  # async: false — re-enables the (globally disabled in test) reauth cache
  # via the app env and works against a shared named ETS table.
  use RuleMaven.DataCase, async: false

  alias RuleMaven.Users
  alias RuleMaven.Users.AuthCache

  setup do
    Application.put_env(:rule_maven, :cache_reauth, true)
    AuthCache.flush()

    on_exit(fn ->
      Application.put_env(:rule_maven, :cache_reauth, false)
      AuthCache.flush()
    end)

    {:ok, user} =
      Users.create_user(%{
        username: "cache_probe_user",
        email: "cache_probe@test.com",
        password: "testpass1234"
      })

    %{user: user}
  end

  test "put/get roundtrip within TTL", %{user: user} do
    assert AuthCache.get(user.id) == :miss

    AuthCache.put(user.id, user)
    assert {:ok, %Users.User{id: id}} = AuthCache.get(user.id)
    assert id == user.id
  end

  test "expired entries are a miss", %{user: user} do
    AuthCache.put(user.id, user)
    [{key, {cached, _stored_at}}] = :ets.lookup(:user_auth_cache, user.id)
    :ets.insert(:user_auth_cache, {key, {cached, System.system_time(:second) - 60}})

    assert AuthCache.get(user.id) == :miss
  end

  test "suspend_user invalidates immediately — revocation beats the TTL", %{user: user} do
    AuthCache.put(user.id, user)
    assert {:ok, _} = AuthCache.get(user.id)

    {:ok, _} = Users.suspend_user(user)
    assert AuthCache.get(user.id) == :miss
  end

  test "unsuspend, force_logout, role change, and delete all invalidate", %{user: user} do
    {:ok, suspended} = Users.suspend_user(user)

    AuthCache.put(user.id, suspended)
    {:ok, user} = Users.unsuspend_user(suspended)
    assert AuthCache.get(user.id) == :miss

    AuthCache.put(user.id, user)
    {:ok, user} = Users.force_logout(user)
    assert AuthCache.get(user.id) == :miss

    AuthCache.put(user.id, user)
    {:ok, user} = Users.update_user_role(user, "admin")
    assert AuthCache.get(user.id) == :miss

    AuthCache.put(user.id, user)
    {:ok, _} = Users.delete_user(user)
    assert AuthCache.get(user.id) == :miss
  end

  test "pubsub broadcast drops the entry (multi-node invalidation path)", %{user: user} do
    AuthCache.put(user.id, user)

    Phoenix.PubSub.broadcast(RuleMaven.PubSub, "users:auth", {:user_auth_invalidated, user.id})
    # The cache GenServer processes the broadcast asynchronously; sync on it.
    _ = :sys.get_state(AuthCache)

    assert :ets.lookup(:user_auth_cache, user.id) == []
  end

  test "disabled cache is a passthrough", %{user: user} do
    Application.put_env(:rule_maven, :cache_reauth, false)

    AuthCache.put(user.id, user)
    assert AuthCache.get(user.id) == :miss
    assert :ets.lookup(:user_auth_cache, user.id) == []
  end
end
