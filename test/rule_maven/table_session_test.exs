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
