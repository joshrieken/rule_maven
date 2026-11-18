defmodule RuleMavenWeb.QuickLoadTest do
  use ExUnit.Case, async: true

  alias RuleMavenWeb.QuickLoad

  test "quick work is returned in time" do
    assert QuickLoad.start(fn -> 1 + 1 end) == {:done, {:ok, 2}}
  end

  test "a raise is an error result, not a crash of the caller" do
    assert {:done, {:error, %RuntimeError{message: "boom"}}} =
             QuickLoad.start(fn -> raise "boom" end)
  end

  test "slow work comes back as a :DOWN message carrying the result" do
    assert {:pending, ref} =
             QuickLoad.start(
               fn ->
                 Process.sleep(60)
                 :late
               end,
               5
             )

    assert_receive {:DOWN, ^ref, :process, _, reason}, 1_000
    assert QuickLoad.result(reason) == {:ok, :late}
  end
end
