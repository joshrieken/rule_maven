defmodule RuleMaven.TableSessionTest do
  use ExUnit.Case, async: false

  alias RuleMaven.TableSession

  test "get on a missing key returns an empty map" do
    assert TableSession.get(-1, -1) == %{}
  end

  test "put then get round-trips the snapshot" do
    :ok = TableSession.put(1, 2, %{tool_states: %{quiz: :expanded}})
    assert TableSession.get(1, 2) == %{tool_states: %{quiz: :expanded}}
  end

  test "put merges into the stored snapshot instead of replacing it" do
    # ToolHost persists only its OWN keys (Map.take(assigns, @session_keys)) on
    # every tool event. Under replace semantics that wiped :active_group_id —
    # a key written by Show's group selector that ToolHost has never heard of —
    # so opening the crew Feed panel silently un-stuck the crew.
    :ok = TableSession.put(7, 8, %{active_group_id: 42})
    :ok = TableSession.put(7, 8, %{tool_states: %{group_feed: :open}})

    snap = TableSession.get(7, 8)
    assert snap[:active_group_id] == 42
    assert snap[:tool_states] == %{group_feed: :open}
  end

  test "put still overwrites a key it does carry (back to Just me)" do
    :ok = TableSession.put(9, 10, %{active_group_id: 42})
    :ok = TableSession.put(9, 10, %{active_group_id: nil})

    assert TableSession.get(9, 10)[:active_group_id] == nil
  end

  test "sweep drops entries older than the TTL, keeps fresh ones" do
    :ok = TableSession.put(3, 4, %{a: 1})

    :ets.insert(
      :rule_maven_table_sessions,
      {{5, 6}, %{b: 2}, System.monotonic_time(:millisecond) - 100_000}
    )

    TableSession.sweep(50_000)
    assert TableSession.get(3, 4) == %{a: 1}
    assert TableSession.get(5, 6) == %{}
  end
end
