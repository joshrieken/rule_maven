defmodule RuleMaven.GroupsManageTest do
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

    test "owner cannot demote themselves via set_role", %{owner: o, group: g} do
      assert {:error, :last_owner} = Groups.set_role(o, g, o.id, "member")
      assert {:error, :last_owner} = Groups.set_role(o, g, o.id, "admin")

      # group still has an owner afterwards
      assert Groups.role_of(o, g) == "owner"
      assert {:error, :owner_must_transfer} = Groups.leave(o, g)
    end

    test "cannot promote to owner via set_role", %{owner: o, member: m, group: g} do
      assert {:error, :use_transfer_ownership} = Groups.set_role(o, g, m.id, "owner")
      assert Groups.role_of(m, g) == "member"
    end
  end

  describe "transfer_ownership/3" do
    test "moves ownership atomically", %{owner: o, member: m, group: g} do
      assert {:ok, _} = Groups.transfer_ownership(o, g, m.id)

      assert Groups.role_of(o, g) == "admin"
      assert Groups.role_of(m, g) == "owner"

      owner_count =
        Groups.list_members(g)
        |> Enum.count(&(&1.role == "owner"))

      assert owner_count == 1

      # new owner can now delete the group
      assert {:ok, :deleted} = Groups.delete_group(m, g)
    end

    test "forbidden for admin and non-member actors", %{owner: o, member: m, group: g} do
      admin = create_user("u18")
      {:ok, _} = Groups.join_by_code(admin, g.invite_code)
      {:ok, _} = Groups.set_role(o, g, admin.id, "admin")

      assert {:error, :forbidden} = Groups.transfer_ownership(admin, g, m.id)

      outsider = create_user("u19")
      assert {:error, :forbidden} = Groups.transfer_ownership(outsider, g, m.id)
    end

    test "target must be a member", %{owner: o, group: g} do
      outsider = create_user("u20")
      assert {:error, :not_member} = Groups.transfer_ownership(o, g, outsider.id)
    end

    test "old owner (now admin) can leave after transfer", %{owner: o, member: m, group: g} do
      assert {:ok, _} = Groups.transfer_ownership(o, g, m.id)
      assert {:ok, :left} = Groups.leave(o, g)
      refute Groups.member?(o, g)
    end

    test "stale authorization is rejected: a former owner cannot transfer again", %{
      owner: o,
      member: m,
      group: g
    } do
      # This proves the auth re-check inside the lock rejects an actor who is
      # no longer the owner at the moment the check runs. It does NOT exercise
      # the true concurrent race (two transactions racing for the advisory
      # lock) — Ecto's SQL sandbox pins a test to a single connection, so two
      # genuinely concurrent transactions aren't reachable here. What this
      # test stands in for: O transfers to M (O becomes "admin"), then O
      # (now stale) tries to transfer again to a third user C. Before the fix,
      # the transaction body re-derived "whoever currently holds role: owner"
      # instead of pinning to the actor, so O's stale authorization would have
      # forced a second, unconsented transfer away from M.
      other = create_user("u21")
      {:ok, _} = Groups.join_by_code(other, g.invite_code)

      assert {:ok, _} = Groups.transfer_ownership(o, g, m.id)
      assert Groups.role_of(o, g) == "admin"
      assert Groups.role_of(m, g) == "owner"

      assert {:error, :forbidden} = Groups.transfer_ownership(o, g, other.id)

      # group still has exactly one owner, and it's still M (the real
      # current owner), not O and not C.
      owner_rows =
        Groups.list_members(g)
        |> Enum.filter(&(&1.role == "owner"))

      assert [%{user_id: owner_id}] = owner_rows
      assert owner_id == m.id
      assert Groups.role_of(other, g) == "member"
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

  describe "account deletion and group ownership (Users.delete_user/1)" do
    defp owner_count(group) do
      Groups.list_members(group) |> Enum.count(&(&1.role == "owner"))
    end

    test "deleting an owner with other members hands off ownership; admin preferred over member",
         %{owner: o, member: m, group: g} do
      # m is a plain "member"; promote a third user to "admin" so both an
      # admin and a plain member exist as heir candidates.
      admin = create_user("u22")
      {:ok, _} = Groups.join_by_code(admin, g.invite_code)
      {:ok, _} = Groups.set_role(o, g, admin.id, "admin")

      assert {:ok, _} = RuleMaven.Users.delete_user(o)

      # group survives
      refute is_nil(RuleMaven.Repo.get(RuleMaven.Groups.Group, g.id))
      assert owner_count(g) == 1
      # the admin was preferred over the plain member
      assert Groups.role_of(admin, g) == "owner"
      assert Groups.role_of(m, g) == "member"
    end

    test "deleting an owner with only plain members promotes the oldest member", %{
      owner: o,
      member: m,
      group: g
    } do
      assert {:ok, _} = RuleMaven.Users.delete_user(o)

      refute is_nil(RuleMaven.Repo.get(RuleMaven.Groups.Group, g.id))
      assert owner_count(g) == 1
      assert Groups.role_of(m, g) == "owner"
    end

    test "deleting an owner who is the group's only member deletes the group" do
      solo_owner = create_user("u23")
      {:ok, solo_group} = Groups.create_group(solo_owner, %{name: "Solo"})

      assert {:ok, _} = RuleMaven.Users.delete_user(solo_owner)

      assert is_nil(RuleMaven.Repo.get(RuleMaven.Groups.Group, solo_group.id))
    end

    test "deleting a plain member leaves the group and its owner untouched", %{
      owner: o,
      member: m,
      group: g
    } do
      assert {:ok, _} = RuleMaven.Users.delete_user(m)

      refute is_nil(RuleMaven.Repo.get(RuleMaven.Groups.Group, g.id))
      assert owner_count(g) == 1
      assert Groups.role_of(o, g) == "owner"
      refute Groups.member?(m, g)
    end

    # Every other test in this describe deletes a QUESTION-LESS user, and that is
    # the only reason they pass. `questions_log.user_id` was `ON DELETE NO ACTION`
    # and `do_delete_user/1` never cleared the user's rows, so `Repo.delete(user)`
    # raised a foreign-key violation for any user who had ever asked anything —
    # rolling back the whole transaction, INCLUDING the ownership handoff above.
    # A crew owner who had used the product could not be deleted at all, and there
    # is no GDPR delete path without this.
    #
    # The rows are nilified, not cascaded: a pooled answer already serves the
    # commons anonymously. Deleting the account anonymizes its questions; it does
    # not retract them.
    test "an owner who has actually ASKED something can still be deleted", %{
      owner: o,
      member: m,
      group: g
    } do
      game = RuleMaven.GamesFixtures.game_fixture(bgg_id: System.unique_integer([:positive]))

      {:ok, q} =
        RuleMaven.Games.log_question(%{
          game_id: game.id,
          user_id: o.id,
          group_id: g.id,
          question: "How do I start?",
          answer: "Roll the die.",
          visibility: "private"
        })

      assert {:ok, _} = RuleMaven.Users.delete_user(o)

      # The handoff still ran — the rollback used to take it with it.
      assert owner_count(g) == 1
      assert Groups.role_of(m, g) == "owner"

      # The question survives, anonymized.
      row = RuleMaven.Repo.get(RuleMaven.Games.QuestionLog, q.id)
      assert row, "the question was destroyed rather than anonymized"
      assert is_nil(row.user_id)
    end
  end
end
