defmodule Mix.Tasks.RuleMaven.Flags.SyncTest do
  use RuleMaven.DataCase, async: false

  alias RuleMaven.Flags.Registry

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{
            username: "#{prefix}_user",
            email: "#{prefix}_user@test.com",
            password: "password1234"
          },
          attrs
        )
      )

    user
  end

  test "seeds missing flags at their defaults and is idempotent" do
    # The tool flags now ship seeded (20260711020000_seed_tool_flags), so
    # "missing" is no longer the database's default state — establish the
    # precondition this test is actually about by clearing one first.
    FunWithFlags.clear(:tool_quiz)

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

  test "sync grants the :asks admin bypass declaratively" do
    admin = create_user("fs_admin", %{role: "admin"})
    regular = create_user("fs_regular")

    {:ok, _} = RuleMaven.Flags.disable(:asks)

    Mix.Tasks.RuleMaven.Flags.Sync.run([])

    assert RuleMaven.Flags.enabled?(:asks, admin)
    refute RuleMaven.Flags.enabled?(:asks, regular)
  after
    FunWithFlags.clear(:asks)
  end
end
