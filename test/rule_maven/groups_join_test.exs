defmodule RuleMaven.GroupsJoinTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Groups

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{username: "#{prefix}_user", email: "#{prefix}_user@test.com", password: "password1234"},
          attrs
        )
      )

    user
  end

  setup do
    owner = create_user("owner")
    {:ok, group} = Groups.create_group(owner, %{name: "Crew"})
    %{owner: owner, group: group}
  end

  test "join_by_code adds a member and bumps the count", %{group: group} do
    joiner = create_user("j1")
    assert {:ok, m} = Groups.join_by_code(joiner, group.invite_code)
    assert m.role == "member"
    assert m.user_id == joiner.id
    assert m.group_id == group.id
    assert Groups.member_count(group) == 2
  end

  test "join_by_code rejects an unknown code", %{} do
    joiner = create_user("j2")
    assert {:error, :invalid_code} = Groups.join_by_code(joiner, "NOPE-NOPE")
  end

  test "join_by_code rejects an inactive invite", %{group: group} do
    {:ok, group} = Groups.set_invite_active(group, false)
    joiner = create_user("j3")
    assert {:error, :inactive} = Groups.join_by_code(joiner, group.invite_code)
  end

  test "join_by_code is idempotent for an existing member", %{owner: owner, group: group} do
    assert {:error, :already_member} = Groups.join_by_code(owner, group.invite_code)
  end

  test "set_invite_active flips the flag", %{group: group} do
    assert {:ok, updated} = Groups.set_invite_active(group, false)
    refute updated.invite_active
  end

  test "set_member_cap updates the cap", %{group: group} do
    assert {:ok, updated} = Groups.set_member_cap(group, 3)
    assert updated.member_cap == 3
  end

  test "member_count reflects the owner immediately after create_group", %{group: group} do
    assert Groups.member_count(group) == 1
  end

  test "join_by_code enforces the member cap sequentially" do
    owner = create_user("capowner")
    {:ok, group} = Groups.create_group(owner, %{name: "Small Crew"})
    {:ok, group} = Groups.set_member_cap(group, 2)

    joiner = create_user("capj1")
    assert {:ok, _} = Groups.join_by_code(joiner, group.invite_code)
    assert Groups.member_count(group) == 2

    overflow = create_user("capj2")
    assert {:error, :full} = Groups.join_by_code(overflow, group.invite_code)
    assert Groups.member_count(group) == 2
  end

  # NOTE: We do NOT assert anything about real concurrent DB connections here.
  # Ecto's SQL sandbox binds a test to a single connection/transaction, so a
  # Task.async_stream of joins in this test does not exercise two genuinely
  # concurrent Postgres transactions racing the advisory lock — it would only
  # prove that repeated sequential calls respect the cap, which the test
  # above already covers. The cap's true concurrency-safety comes from
  # pg_advisory_xact_lock serializing joiners per group id inside
  # Repo.transaction/1 (see Groups.join_by_code/2); that guarantee is a
  # property of Postgres locking semantics, not something provable from
  # within the sandboxed test suite.
end
