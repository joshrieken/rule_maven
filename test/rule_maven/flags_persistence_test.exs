defmodule RuleMaven.FlagsPersistenceTest do
  use RuleMaven.DataCase, async: false

  test "a boolean flag round-trips through the DB" do
    refute FunWithFlags.enabled?(:__test_persist_flag)
    {:ok, true} = FunWithFlags.enable(:__test_persist_flag)
    assert FunWithFlags.enabled?(:__test_persist_flag)
    {:ok, false} = FunWithFlags.disable(:__test_persist_flag)
    refute FunWithFlags.enabled?(:__test_persist_flag)
  end
end
