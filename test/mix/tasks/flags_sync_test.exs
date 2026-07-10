defmodule Mix.Tasks.RuleMaven.Flags.SyncTest do
  use RuleMaven.DataCase, async: false

  alias RuleMaven.Flags.Registry

  test "seeds missing flags at their defaults and is idempotent" do
    # nothing persisted yet
    {:ok, before} = FunWithFlags.all_flag_names()
    refute :tool_quiz in before

    Mix.Tasks.RuleMaven.Flags.Sync.run([])

    assert RuleMaven.Flags.enabled?(:tool_quiz, nil)

    # second run must not raise or change state
    Mix.Tasks.RuleMaven.Flags.Sync.run([])
    assert RuleMaven.Flags.enabled?(:tool_quiz, nil)

    {:ok, after_names} = FunWithFlags.all_flag_names()
    assert Enum.sort(Enum.uniq(after_names)) |> length() >= length(Registry.ids())
  after
    for id <- Registry.ids(), do: FunWithFlags.clear(id)
  end

  test "--check raises when a declared flag is unsynced" do
    assert_raise Mix.Error, fn ->
      Mix.Tasks.RuleMaven.Flags.Sync.run(["--check"])
    end
  end
end
