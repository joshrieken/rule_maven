defmodule RuleMaven.GroupsManageTest do
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
    owner = create_user("u1")
    {:ok, group} = Groups.create_group(owner, %{name: "Crew"})
    member = create_user("u2")
    {:ok, _} = Groups.join_by_code(member, group.invite_code)
    %{owner: owner, member: member, group: group}
  end

  describe "member?/2 and role_at_least?/3" do
    test "ranks owner > admin > member", %{owner: o, member: m, group: g} do
      assert Groups.role_at_least?(o, g, :member)
      assert Groups.role_at_least?(o, g, :owner)
      assert Groups.role_at_least?(m, g, :member)
      refute Groups.role_at_least?(m, g, :admin)
      refute Groups.member?(create_user("u3"), g)
      assert Groups.member?(o, g)
      assert Groups.member?(m, g)
    end

    test "role_at_least? accepts string role too", %{owner: o, group: g} do
      assert Groups.role_at_least?(o, g, "owner")
      assert Groups.role_at_least?(o, g, "admin")
    end

    test "member? and role_at_least? are false for a nil user", %{group: g} do
      refute Groups.member?(nil, g)
      refute Groups.role_at_least?(nil, g, :member)
    end
  end

  describe "list_for_user/1" do
    test "returns [] for nil" do
      assert Groups.list_for_user(nil) == []
    end

    test "returns groups the user belongs to", %{owner: o, member: m, group: g} do
      assert [%RuleMaven.Groups.Group{id: gid}] = Groups.list_for_user(o)
      assert gid == g.id
      assert [%RuleMaven.Groups.Group{id: gid2}] = Groups.list_for_user(m)
      assert gid2 == g.id

      outsider = create_user("u4")
      assert Groups.list_for_user(outsider) == []
    end
  end

  describe "list_members/1" do
    test "lists members with role and username", %{owner: o, member: m, group: g} do
      members = Groups.list_members(g)
      assert length(members) == 2
      assert %{user_id: o.id, username: o.username, role: "owner"} in members
      assert %{user_id: m.id, username: m.username, role: "member"} in members
    end
  end

  describe "rename/3" do
    test "owner and admin can rename; member cannot; non-member cannot", %{
      owner: o,
      member: m,
      group: g
    } do
      assert {:error, :forbidden} = Groups.rename(m, g, "Nope")
      assert {:error, :forbidden} = Groups.rename(create_user("u5"), g, "Nope")

      assert {:ok, g2} = Groups.rename(o, g, "New Name")
      assert g2.name == "New Name"

      {:ok, _} = Groups.set_role(o, g2, m.id, "admin")
      assert {:ok, g3} = Groups.rename(m, g2, "Admin Renamed")
      assert g3.name == "Admin Renamed"
    end

    test "invalid name returns a changeset error", %{owner: o, group: g} do
      assert {:error, %Ecto.Changeset{}} = Groups.rename(o, g, "")
    end
  end

  describe "regenerate_code/2" do
    test "old code invalidated, forbidden for member/non-member, allowed for admin", %{
      owner: o,
      member: m,
      group: g
    } do
      old = g.invite_code
      assert {:error, :forbidden} = Groups.regenerate_code(m, g)
      assert {:error, :forbidden} = Groups.regenerate_code(create_user("u6"), g)

      assert {:ok, g2} = Groups.regenerate_code(o, g)
      refute g2.invite_code == old
      assert {:error, :invalid_code} = Groups.join_by_code(create_user("u7"), old)

      # admin can also regenerate
      {:ok, _} = Groups.set_role(o, g2, m.id, "admin")
      old2 = g2.invite_code
      assert {:ok, g3} = Groups.regenerate_code(m, g2)
      refute g3.invite_code == old2
    end
  end

  describe "set_role/4" do
    test "only owner can promote/demote", %{owner: o, member: m, group: g} do
      victim = create_user("u8")
      {:ok, _} = Groups.join_by_code(victim, g.invite_code)

      assert {:error, :forbidden} = Groups.set_role(m, g, victim.id, "admin")
      assert {:ok, membership} = Groups.set_role(o, g, victim.id, "admin")
      assert membership.role == "admin"

      # admin (m is still just member here) cannot set_role even after promoting victim
      assert {:error, :forbidden} = Groups.set_role(victim, g, m.id, "admin")
    end

    test "set_role on non-member returns :not_member", %{owner: o, group: g} do
      outsider = create_user("u9")
      assert {:error, :not_member} = Groups.set_role(o, g, outsider.id, "admin")
    end

    test "non-member actor gets :forbidden", %{group: g} do
      target = create_user("u10")
      assert {:error, :forbidden} = Groups.set_role(create_user("u11"), g, target.id, "admin")
    end
  end

  describe "remove_member/3" do
    test "member cannot remove; admin can", %{owner: o, member: m, group: g} do
      victim = create_user("u12")
      {:ok, _} = Groups.join_by_code(victim, g.invite_code)

      assert {:error, :forbidden} = Groups.remove_member(m, g, victim.id)
      {:ok, _} = Groups.set_role(o, g, m.id, "admin")
      assert {:ok, :removed} = Groups.remove_member(m, g, victim.id)
      refute Groups.member?(victim, g)
    end

    test "cannot remove the owner", %{owner: o, group: g} do
      admin = create_user("u13")
      {:ok, _} = Groups.join_by_code(admin, g.invite_code)
      {:ok, _} = Groups.set_role(o, g, admin.id, "admin")
      assert {:error, :cannot_remove_owner} = Groups.remove_member(admin, g, o.id)
    end

    test "non-member actor gets :forbidden", %{owner: o, group: g} do
      outsider = create_user("u14")
      assert {:error, :forbidden} = Groups.remove_member(outsider, g, o.id)
    end

    test "removing a non-member target returns :not_member", %{owner: o, group: g} do
      outsider = create_user("u15")
      assert {:error, :not_member} = Groups.remove_member(o, g, outsider.id)
    end
  end

  describe "leave/2" do
    test "owner must transfer before leaving; member can leave freely", %{
      owner: o,
      member: m,
      group: g
    } do
      assert {:error, :owner_must_transfer} = Groups.leave(o, g)
      assert {:ok, :left} = Groups.leave(m, g)
      refute Groups.member?(m, g)
    end

    test "non-member leaving returns :not_member", %{group: g} do
      outsider = create_user("u16")
      assert {:error, :not_member} = Groups.leave(outsider, g)
    end
  end

  describe "delete_group/2" do
    test "delete is owner-only; admin cannot delete", %{owner: o, member: m, group: g} do
      {:ok, _} = Groups.set_role(o, g, m.id, "admin")
      assert {:error, :forbidden} = Groups.delete_group(m, g)
      assert {:error, :forbidden} = Groups.delete_group(create_user("u17"), g)
      assert {:ok, :deleted} = Groups.delete_group(o, g)
    end
  end
end
