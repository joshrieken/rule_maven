defmodule RuleMaven.FlagsTest do
  use RuleMaven.DataCase, async: false

  alias RuleMaven.Flags
  alias RuleMaven.Flags.Registry

  defp user(role) do
    {:ok, u} =
      RuleMaven.Users.create_user(%{
        username: "u#{System.unique_integer([:positive])}",
        email: "u#{System.unique_integer([:positive])}@test.com",
        password: "password1234",
        role: role
      })

    u
  end

  test "registry declares the 11 tool flags plus the two kill switches" do
    ids = Registry.ids()
    assert :tool_quiz in ids
    assert :tool_house_rules in ids
    assert :asks in ids
    assert :outbound_email in ids
    assert length(Registry.all()) == 13
    assert Enum.all?(Registry.all(), &(&1.kind == :ops))
  end

  test "enabled?/2 raises on an unregistered id" do
    assert_raise KeyError, fn -> Flags.enabled?(:not_a_real_flag) end
  end

  test "actor id is stable and prefixed" do
    u = user("user")
    assert FunWithFlags.Actor.id(u) == "user:#{u.id}"
  end

  test "an admin group override beats a disabled boolean gate" do
    {:ok, _} = Flags.disable(:tool_quiz)
    {:ok, _} = Flags.enable_for_admins(:tool_quiz)

    regular = user("user")
    admin = user("admin")

    refute Flags.enabled?(:tool_quiz, regular)
    assert Flags.enabled?(:tool_quiz, admin)
    refute Flags.enabled?(:tool_quiz, nil)
  after
    FunWithFlags.clear(:tool_quiz)
  end
end
