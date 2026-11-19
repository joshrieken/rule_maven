defmodule Mix.Tasks.RuleMaven.RefuseDevWriteTest do
  use ExUnit.Case, async: true

  import Mix.Tasks.RuleMaven.ResetPrepared, only: [refuse_dev_write!: 2]

  test "content tasks refuse to write to dev" do
    assert_raise Mix.Error, ~r/production is the source of truth/, fn ->
      refuse_dev_write!(:dev, nil)
    end
  end

  test "RULEMAVEN_DEV_WRITE=1 allows a deliberate dev write" do
    assert refuse_dev_write!(:dev, "1") == :ok
  end

  test "prod (bin/prod) and test runs are untouched" do
    assert refuse_dev_write!(:prod, nil) == :ok
    assert refuse_dev_write!(:test, nil) == :ok
  end
end
