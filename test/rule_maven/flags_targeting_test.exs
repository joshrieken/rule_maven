defmodule RuleMaven.FlagsTargetingTest do
  use RuleMaven.DataCase, async: false

  alias RuleMaven.Flags

  defp user do
    {:ok, u} =
      RuleMaven.Users.create_user(%{
        username: "u#{System.unique_integer([:positive])}",
        email: "u#{System.unique_integer([:positive])}@test.com",
        password: "password1234",
        role: "user"
      })

    u
  end

  test "grant_actor makes the flag on for that user even when boolean is off" do
    u = user()
    other = user()
    {:ok, _} = Flags.disable(:tool_quiz)
    {:ok, _} = Flags.grant_actor(:tool_quiz, u)

    assert Flags.enabled?(:tool_quiz, u)
    refute Flags.enabled?(:tool_quiz, other)
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "revoke_actor reverts the user to the boolean outcome" do
    u = user()
    {:ok, _} = Flags.disable(:tool_quiz)
    {:ok, _} = Flags.grant_actor(:tool_quiz, u)
    assert Flags.enabled?(:tool_quiz, u)

    :ok = Flags.revoke_actor(:tool_quiz, u)
    refute Flags.enabled?(:tool_quiz, u)
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "set_percentage writes a percentage gate; 0 clears it; >=1 raises" do
    {:ok, _} = Flags.set_percentage(:tool_quiz, 0.25)
    assert Flags.gates(:tool_quiz).percentage == 0.25

    :ok = Flags.set_percentage(:tool_quiz, 0)
    assert Flags.gates(:tool_quiz).percentage == nil

    assert_raise ArgumentError, fn -> Flags.set_percentage(:tool_quiz, 1.0) end
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "gates/1 normalizes boolean, actor, and percentage gates" do
    u = user()
    {:ok, _} = Flags.enable(:tool_quiz)
    {:ok, _} = Flags.grant_actor(:tool_quiz, u)
    {:ok, _} = Flags.set_percentage(:tool_quiz, 0.4)

    g = Flags.gates(:tool_quiz)
    assert g.boolean == true
    assert g.percentage == 0.4
    assert "user:#{u.id}" in g.actors
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "gates/1 on an unregistered flag raises (registry validation)" do
    assert_raise KeyError, fn -> Flags.gates(:not_a_real_flag) end
  end
end
