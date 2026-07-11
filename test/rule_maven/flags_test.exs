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

  test "registry declares the 12 tool flags plus the two kill switches plus the experiment" do
    ids = Registry.ids()
    assert :tool_quiz in ids
    assert :tool_house_rules in ids
    assert :tool_group_feed in ids
    assert :asks in ids
    assert :outbound_email in ids
    assert :exp_ask_pipeline in ids
    assert length(Registry.all()) == 15
    assert Enum.count(Registry.all(), &(&1.kind == :ops)) == 14
    assert Enum.count(Registry.all(), &(&1.kind == :experiment)) == 1
  end

  test "enabled?/2 raises on an unregistered id" do
    assert_raise KeyError, fn -> Flags.enabled?(:not_a_real_flag) end
  end

  test "actor id is stable and prefixed" do
    u = user("user")
    assert FunWithFlags.Actor.id(u) == "user:#{u.id}"
  end

  test "every tool has a matching :tool_* flag and vice versa" do
    tool_ids = RuleMavenWeb.GameLive.ToolRegistry.ids()
    expected_flags_for_tools = Enum.map(tool_ids, &:"tool_#{&1}")

    tool_flag_ids =
      Registry.ids()
      |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "tool_"))

    missing_flags = expected_flags_for_tools -- tool_flag_ids
    orphaned_flags = tool_flag_ids -- expected_flags_for_tools

    assert missing_flags == [],
           "tool(s) with no matching flag (would ship ungated): #{inspect(missing_flags)}"

    assert orphaned_flags == [],
           "flag(s) with no matching tool: #{inspect(orphaned_flags)}"
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
