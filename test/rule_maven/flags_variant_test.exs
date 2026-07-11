defmodule RuleMaven.FlagsVariantTest do
  use RuleMaven.DataCase, async: false

  alias RuleMaven.Flags
  alias RuleMaven.Flags.ExperimentAssignment
  import Ecto.Query

  @exp :exp_ask_pipeline

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

  defp count_rows(exp) do
    RuleMaven.Repo.aggregate(
      from(a in ExperimentAssignment, where: a.experiment == ^to_string(exp)),
      :count
    )
  end

  test "variant is :control when the gate is off, and records it" do
    u = user()
    assert Flags.variant(@exp, u) == :control
    assert count_rows(@exp) == 1
  after
    FunWithFlags.clear(@exp)
  end

  test "variant is :treatment when the gate is on for the user" do
    u = user()
    {:ok, _} = Flags.grant_actor(@exp, u)
    assert Flags.variant(@exp, u) == :treatment
  after
    FunWithFlags.clear(@exp)
  end

  test "variant is consistent with enabled? on the same flag" do
    u = user()
    {:ok, _} = Flags.grant_actor(@exp, u)
    assert Flags.enabled?(@exp, u) == (Flags.variant(@exp, u) == :treatment)
  after
    FunWithFlags.clear(@exp)
  end

  test "a second call for the same user+experiment does not insert a duplicate" do
    u = user()
    Flags.variant(@exp, u)
    Flags.variant(@exp, u)
    assert count_rows(@exp) == 1
  after
    FunWithFlags.clear(@exp)
  end

  test "nil user is :control and records nothing" do
    assert Flags.variant(@exp, nil) == :control
    assert count_rows(@exp) == 0
  after
    FunWithFlags.clear(@exp)
  end

  test "variant raises on a non-experiment flag" do
    u = user()
    assert_raise ArgumentError, fn -> Flags.variant(:tool_quiz, u) end
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "variant raises ArgumentError on a non-User, non-nil second arg" do
    assert_raise ArgumentError, fn -> Flags.variant(@exp, 123) end
  after
    FunWithFlags.clear(@exp)
  end

  test "assignment_counts returns per-variant counts" do
    u1 = user()
    u2 = user()
    {:ok, _} = Flags.grant_actor(@exp, u1)
    # treatment
    Flags.variant(@exp, u1)
    # control
    Flags.variant(@exp, u2)

    counts = Flags.assignment_counts(@exp)
    assert counts.treatment == 1
    assert counts.control == 1
  after
    FunWithFlags.clear(@exp)
  end
end
