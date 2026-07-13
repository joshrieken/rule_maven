defmodule RuleMaven.GroupsTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Groups

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

  test "create_group inserts group + owner membership" do
    owner = create_user("owner")
    {:ok, group} = Groups.create_group(owner, %{name: "Game Night"})
    assert group.name == "Game Night"
    assert group.owner_id == owner.id
    assert String.length(group.invite_code) > 0
    assert Groups.role_of(owner, group) == "owner"
  end

  test "get_group_by_token round-trips the hashid" do
    owner = create_user("crew")
    {:ok, group} = Groups.create_group(owner, %{name: "Crew"})
    token = Phoenix.Param.to_param(group)
    assert Groups.get_group_by_token(token).id == group.id
    assert Groups.get_group_by_token("not-a-token") == nil
  end

  test "role_of tolerates a nil user" do
    owner = create_user("solo")
    {:ok, group} = Groups.create_group(owner, %{name: "Solo"})
    assert Groups.role_of(nil, group) == nil
  end

  test "create_group rolls back on invalid attrs, leaving no orphan membership" do
    owner = create_user("bad")
    assert {:error, _changeset} = Groups.create_group(owner, %{name: ""})
    assert Groups.role_of(owner, %RuleMaven.Groups.Group{id: -1}) == nil
  end

  test "admin_rename renames without requiring group membership" do
    owner = create_user("adminrename_owner")
    {:ok, group} = Groups.create_group(owner, %{name: "Old Name"})

    assert {:ok, updated} = Groups.admin_rename(group, "New Name")
    assert updated.name == "New Name"
  end

  test "admin_rename returns a changeset error for an invalid name" do
    owner = create_user("adminrename_bad")
    {:ok, group} = Groups.create_group(owner, %{name: "Fine"})

    assert {:error, %Ecto.Changeset{}} = Groups.admin_rename(group, "")
  end

  test "admin_set_invite_active flips the flag without membership" do
    owner = create_user("adminflag_owner")
    {:ok, group} = Groups.create_group(owner, %{name: "Flag Crew"})

    assert {:ok, updated} = Groups.admin_set_invite_active(group, false)
    refute updated.invite_active
  end

  test "admin_set_member_cap changes the cap without membership" do
    owner = create_user("admincap_owner")
    {:ok, group} = Groups.create_group(owner, %{name: "Cap Crew"})

    assert {:ok, updated} = Groups.admin_set_member_cap(group, 5)
    assert updated.member_cap == 5
  end

  test "admin_set_member_cap rejects a non-positive cap" do
    owner = create_user("admincap_bad")
    {:ok, group} = Groups.create_group(owner, %{name: "Cap Crew 2"})

    assert {:error, %Ecto.Changeset{}} = Groups.admin_set_member_cap(group, 0)
  end

  test "admin_regenerate_code rotates the code without membership" do
    owner = create_user("adminregen_owner")
    {:ok, group} = Groups.create_group(owner, %{name: "Regen Crew"})
    old_code = group.invite_code

    updated = Groups.admin_regenerate_code(group)
    assert updated.invite_code != old_code
  end

  test "admin_set_role promotes a member without being in the group" do
    owner = create_user("adminrole_owner")
    {:ok, group} = Groups.create_group(owner, %{name: "Role Crew"})
    member = create_user("adminrole_member")
    {:ok, _} = Groups.join_by_code(member, group.invite_code)

    assert {:ok, membership} = Groups.admin_set_role(group, member.id, "admin")
    assert membership.role == "admin"
  end

  test "admin_set_role refuses to touch an owner row" do
    owner = create_user("adminrole_owner2")
    {:ok, group} = Groups.create_group(owner, %{name: "Role Crew 2"})

    assert {:error, :last_owner} = Groups.admin_set_role(group, owner.id, "member")
  end

  test "admin_set_role refuses to promote to owner" do
    owner = create_user("adminrole_owner3")
    {:ok, group} = Groups.create_group(owner, %{name: "Role Crew 3"})
    member = create_user("adminrole_member3")
    {:ok, _} = Groups.join_by_code(member, group.invite_code)

    assert {:error, :use_transfer_ownership} = Groups.admin_set_role(group, member.id, "owner")
  end

  test "admin_set_role rejects a garbage role" do
    owner = create_user("adminrole_owner4")
    {:ok, group} = Groups.create_group(owner, %{name: "Role Crew 4"})
    member = create_user("adminrole_member4")
    {:ok, _} = Groups.join_by_code(member, group.invite_code)

    assert {:error, :invalid_role} = Groups.admin_set_role(group, member.id, "wizard")
  end

  test "admin_transfer_ownership moves ownership without being in the group" do
    owner = create_user("admintransfer_owner")
    {:ok, group} = Groups.create_group(owner, %{name: "Transfer Crew"})
    member = create_user("admintransfer_member")
    {:ok, _} = Groups.join_by_code(member, group.invite_code)

    assert {:ok, updated} = Groups.admin_transfer_ownership(group, member.id)
    assert updated.owner_id == member.id
    assert Groups.role_of(member, updated) == "owner"
    assert Groups.role_of(owner, updated) == "admin"
  end

  test "admin_transfer_ownership rejects a non-member target" do
    owner = create_user("admintransfer_owner2")
    {:ok, group} = Groups.create_group(owner, %{name: "Transfer Crew 2"})
    outsider = create_user("admintransfer_outsider")

    assert {:error, :not_member} = Groups.admin_transfer_ownership(group, outsider.id)
  end

  test "admin_remove_member removes a member without being in the group" do
    owner = create_user("adminremove_owner")
    {:ok, group} = Groups.create_group(owner, %{name: "Remove Crew"})
    member = create_user("adminremove_member")
    {:ok, _} = Groups.join_by_code(member, group.invite_code)

    assert {:ok, :removed} = Groups.admin_remove_member(group, member.id)
    refute Groups.member?(member, group)
  end

  test "admin_remove_member refuses to remove the owner" do
    owner = create_user("adminremove_owner2")
    {:ok, group} = Groups.create_group(owner, %{name: "Remove Crew 2"})

    assert {:error, :cannot_remove_owner} = Groups.admin_remove_member(group, owner.id)
  end

  test "admin_remove_member rejects a non-member target" do
    owner = create_user("adminremove_owner3")
    {:ok, group} = Groups.create_group(owner, %{name: "Remove Crew 3"})
    outsider = create_user("adminremove_outsider")

    assert {:error, :not_member} = Groups.admin_remove_member(group, outsider.id)
  end

  test "admin_delete_group deletes without being in the group" do
    owner = create_user("admindelete_owner")
    {:ok, group} = Groups.create_group(owner, %{name: "Delete Crew"})

    assert {:ok, :deleted} = Groups.admin_delete_group(group)
    assert Groups.get_group_by_token(Phoenix.Param.to_param(group)) == nil
  end

  test "list_all returns every group with member_count and owner_username" do
    owner1 = create_user("listall_owner1")
    owner2 = create_user("listall_owner2")
    {:ok, group1} = Groups.create_group(owner1, %{name: "Alpha Crew"})
    {:ok, group2} = Groups.create_group(owner2, %{name: "Beta Crew"})
    member = create_user("listall_member")
    {:ok, _} = Groups.join_by_code(member, group1.invite_code)

    rows = Groups.list_all()
    ids = Enum.map(rows, & &1.group.id)
    assert group1.id in ids
    assert group2.id in ids

    row1 = Enum.find(rows, &(&1.group.id == group1.id))
    assert row1.member_count == 2
    assert row1.owner_username == owner1.username
  end

  test "list_all filters by name search, case-insensitive" do
    owner = create_user("listall_search_owner")
    {:ok, _} = Groups.create_group(owner, %{name: "Searchable Crew"})
    {:ok, _} = Groups.create_group(owner, %{name: "Other Crew"})

    rows = Groups.list_all("searchable")
    assert length(rows) == 1
    assert hd(rows).group.name == "Searchable Crew"
  end
end
