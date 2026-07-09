defmodule RuleMaven.LLM.SingleflightTest do
  use ExUnit.Case, async: false

  alias RuleMaven.LLM.Singleflight

  setup do
    # The app already starts Singleflight; make sure no key leaks across tests.
    key = Singleflight.ask_key(System.unique_integer([:positive]), [], "how many players?")
    on_exit(fn -> Singleflight.release(key) end)
    %{key: key}
  end

  test "the first caller leads and the second follows only after release", %{key: key} do
    test_pid = self()

    leader =
      spawn(fn ->
        assert Singleflight.acquire(key) == :leader
        send(test_pid, :leading)
        # Hold the key until told to let go.
        receive do: (:finish -> :ok)
        Singleflight.release(key)
        send(test_pid, :released)
      end)

    assert_receive :leading, 1_000

    spawn(fn ->
      assert Singleflight.acquire(key, 2_000) == :follower
      send(test_pid, :followed)
    end)

    # The follower must still be blocked while the leader holds the key.
    refute_receive :followed, 200

    send(leader, :finish)
    assert_receive :released, 1_000
    assert_receive :followed, 1_000
  end

  test "a crashed leader releases the key and wakes its followers", %{key: key} do
    test_pid = self()

    leader =
      spawn(fn ->
        assert Singleflight.acquire(key) == :leader
        send(test_pid, :leading)
        receive do: (:never -> :ok)
      end)

    assert_receive :leading, 1_000

    spawn(fn ->
      assert Singleflight.acquire(key, 2_000) == :follower
      send(test_pid, :followed)
    end)

    refute_receive :followed, 200

    # Mirrors AskWorker.run_bounded/2 brutal-killing a wedged ask.
    Process.exit(leader, :kill)

    assert_receive :followed, 1_000

    # Key is free again: the next caller leads rather than waiting on a corpse.
    assert Singleflight.acquire(key) == :leader
    Singleflight.release(key)
  end

  test "a follower gives up after its wait budget and proceeds anyway", %{key: key} do
    test_pid = self()

    spawn(fn ->
      assert Singleflight.acquire(key) == :leader
      send(test_pid, :leading)
      receive do: (:never -> :ok)
    end)

    assert_receive :leading, 1_000

    # Correctness never depends on the lock — a follower that times out proceeds.
    assert Singleflight.acquire(key, 50) == :follower
  end

  test "release by a non-leader does not free someone else's key", %{key: key} do
    test_pid = self()

    spawn(fn ->
      assert Singleflight.acquire(key) == :leader
      send(test_pid, :leading)
      receive do: (:never -> :ok)
    end)

    assert_receive :leading, 1_000

    # This process never held the key; releasing it must be a no-op.
    Singleflight.release(key)
    # Give the cast time to land.
    Process.sleep(50)

    assert Singleflight.acquire(key, 50) == :follower
  end

  test "ask_key ignores case, surrounding space, and expansion order" do
    a = Singleflight.ask_key(1, [3, 7], "  How Many Players? ")
    b = Singleflight.ask_key(1, [7, 3], "how many players?")
    assert a == b

    refute a == Singleflight.ask_key(2, [3, 7], "how many players?")
    refute a == Singleflight.ask_key(1, [3], "how many players?")
    refute a == Singleflight.ask_key(1, [3, 7], "how many pieces?")
  end
end
