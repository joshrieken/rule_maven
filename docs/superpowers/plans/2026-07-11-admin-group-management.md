# Admin Group Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any site admin (`Users.can?(user, :admin)`) view every persistent group and perform every mutation a group's own owner/admin could perform, from a new `/admin/groups` section — without needing to be a member of that group.

**Architecture:** Split each actor-gated `RuleMaven.Groups` mutator into a private `do_*` mechanics function plus two public callers — the existing role-checked wrapper (unchanged), and a new `admin_*` wrapper with no membership check. Two new admin LiveViews (list + detail) call the `admin_*` functions and audit-log every mutation, reusing `GroupLive.Show`'s member-management UI patterns.

**Tech Stack:** Phoenix LiveView, Ecto, Postgres advisory locks (existing pattern in `RuleMaven.Groups`), `RuleMaven.Audit`.

## Global Constraints

- Gate: `Users.can?(current_user, :admin)` — no super-admin split (per spec: "Scope").
- Every admin mutation logs via `RuleMaven.Audit.log/3` with `target_type: "group"`.
- All existing invariants in `RuleMaven.Groups` (single-owner uniqueness, member-cap > 0, owner can't be removed directly, retroactive contribution retraction, advisory-lock critical sections) must hold unchanged for both the actor-gated and admin paths — the `do_*` extraction must not change any of that logic, only who's allowed to call it.
- Routes live inside the existing `live_session :admin` scope in `lib/rule_maven_web/router.ex`.
- Follow existing admin LiveView conventions: `mount/3` gate + redirect-with-flash on denial (see `lib/rule_maven_web/live/admin_live/themes.ex:1-16` for the minimal shape, `lib/rule_maven_web/live/admin_live/invites.ex:1-17` for the audit-logging shape).

---

## Task 1: `Groups.rename` / `Groups.admin_rename`

**Files:**
- Modify: `lib/rule_maven/groups.ex:273-287` (the `rename/3` function)
- Test: `test/rule_maven/groups_test.exs`

**Interfaces:**
- Consumes: nothing new (uses existing `Group.changeset/2`, `Repo.update/1`, `role_at_least?/3`)
- Produces: `Groups.admin_rename/2 :: (Group.t(), String.t()) -> {:ok, Group.t()} | {:error, Ecto.Changeset.t()}` — used by Task 12.

- [ ] **Step 1: Write the failing test**

Add to `test/rule_maven/groups_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/groups_test.exs -v`
Expected: FAIL with `undefined function admin_rename/2`

- [ ] **Step 3: Implement — split `rename/3` into `do_rename/2` + `rename/3` + `admin_rename/2`**

In `lib/rule_maven/groups.ex`, replace the existing `rename/3`:

```elixir
  @doc """
  Renames the group. Requires the actor to be at least an admin.

  Returns `{:ok, group}`, `{:error, :forbidden}`, or `{:error, changeset}`
  for an invalid name.
  """
  def rename(actor, group, name) do
    if role_at_least?(actor, group, :admin) do
      do_rename(group, name)
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Renames the group with no membership/role check. For site-admin callers
  only — the caller is responsible for verifying `Users.can?(actor, :admin)`
  before calling this. Same validation and return shape as `rename/3` minus
  the `:forbidden` case.
  """
  def admin_rename(%Group{} = group, name), do: do_rename(group, name)

  defp do_rename(group, name) do
    group
    |> Group.changeset(%{name: name})
    |> Repo.update()
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/groups_test.exs -v`
Expected: PASS (all tests in the file, including the two new ones)

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/groups.ex test/rule_maven/groups_test.exs
git commit -m "feat(groups): add admin_rename bypassing group-role check"
```

---

## Task 2: `Groups.admin_set_invite_active` and `Groups.admin_set_member_cap`

**Files:**
- Modify: `lib/rule_maven/groups.ex:104-135` (`set_invite_active/3`, `set_member_cap/3`)
- Test: `test/rule_maven/groups_test.exs`

**Interfaces:**
- Consumes: `Group.changeset/2`, `Repo.update/1`
- Produces:
  - `Groups.admin_set_invite_active/2 :: (Group.t(), boolean()) -> {:ok, Group.t()} | {:error, Ecto.Changeset.t()}`
  - `Groups.admin_set_member_cap/2 :: (Group.t(), integer()) -> {:ok, Group.t()} | {:error, Ecto.Changeset.t()}`

- [ ] **Step 1: Write the failing tests**

Add to `test/rule_maven/groups_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/groups_test.exs -v`
Expected: FAIL with `undefined function admin_set_invite_active/2` (and `admin_set_member_cap/2`)

- [ ] **Step 3: Implement**

Replace `set_invite_active/3` and `set_member_cap/3` in `lib/rule_maven/groups.ex`:

```elixir
  @doc """
  Flips whether the group's invite code currently accepts new joins.
  Requires the actor to be at least an admin.
  """
  def set_invite_active(actor, %Group{} = group, active?) when is_boolean(active?) do
    if role_at_least?(actor, group, :admin) do
      do_set_invite_active(group, active?)
    else
      {:error, :forbidden}
    end
  end

  @doc "Same as `set_invite_active/3`, no membership check. Site-admin callers only."
  def admin_set_invite_active(%Group{} = group, active?) when is_boolean(active?) do
    do_set_invite_active(group, active?)
  end

  defp do_set_invite_active(group, active?) do
    group
    |> Group.changeset(%{invite_active: active?})
    |> Repo.update()
  end

  @doc """
  Sets the maximum number of members the group may hold. Admin or owner only.
  """
  def set_member_cap(actor, %Group{} = group, cap) when is_integer(cap) do
    if role_at_least?(actor, group, :admin) do
      do_set_member_cap(group, cap)
    else
      {:error, :forbidden}
    end
  end

  @doc "Same as `set_member_cap/3`, no membership check. Site-admin callers only."
  def admin_set_member_cap(%Group{} = group, cap) when is_integer(cap) do
    do_set_member_cap(group, cap)
  end

  defp do_set_member_cap(group, cap) do
    group
    |> Group.changeset(%{member_cap: cap})
    |> Repo.update()
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/groups_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/groups.ex test/rule_maven/groups_test.exs
git commit -m "feat(groups): add admin_set_invite_active and admin_set_member_cap"
```

---

## Task 3: `Groups.admin_set_contribute`

**Files:**
- Modify: `lib/rule_maven/groups.ex:301-321` (`set_contribute/3`)
- Test: `test/rule_maven/groups_test.exs`

**Interfaces:**
- Consumes: `retract_contributions/1` (existing private function, unchanged)
- Produces: `Groups.admin_set_contribute/2 :: (Group.t(), boolean()) -> {:ok, Group.t()} | {:error, Ecto.Changeset.t()}`

- [ ] **Step 1: Write the failing tests**

Add to `test/rule_maven/groups_test.exs`:

```elixir
  test "admin_set_contribute turns contribution off without membership" do
    owner = create_user("admincontrib_owner")
    {:ok, group} = Groups.create_group(owner, %{name: "Contrib Crew"})

    assert {:ok, updated} = Groups.admin_set_contribute(group, false)
    refute updated.contribute_to_community
    refute Groups.contribute_to_community?(updated.id)
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/groups_test.exs -v`
Expected: FAIL with `undefined function admin_set_contribute/2`

- [ ] **Step 3: Implement**

Replace `set_contribute/3` in `lib/rule_maven/groups.ex`:

```elixir
  @doc """
  Sets whether the group's answers contribute to the community cache
  (`contribute_to_community`). Requires the actor to be at least an admin —
  same authorization shape as `rename/3`, via `role_at_least?/3`. A caller
  without permission gets `{:error, :forbidden}`, like every other function in
  this module.

  When off, `AskWorker` forces `never_pool` for every ask made under this
  group (see `contribute_to_community?/1`); the group's questions stay
  private either way, this only affects whether the *answers* feed the
  shared community cache.
  """
  def set_contribute(actor, %Group{} = group, contribute?) when is_boolean(contribute?) do
    if role_at_least?(actor, group, :admin) do
      do_set_contribute(group, contribute?)
    else
      {:error, :forbidden}
    end
  end

  @doc "Same as `set_contribute/3`, no membership check. Site-admin callers only."
  def admin_set_contribute(%Group{} = group, contribute?) when is_boolean(contribute?) do
    do_set_contribute(group, contribute?)
  end

  defp do_set_contribute(group, contribute?) do
    Repo.transaction(fn ->
      result =
        group
        |> Group.changeset(%{contribute_to_community: contribute?})
        |> Repo.update()

      case result do
        {:ok, updated} ->
          if not contribute?, do: retract_contributions(group)
          updated

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/groups_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/groups.ex test/rule_maven/groups_test.exs
git commit -m "feat(groups): add admin_set_contribute"
```

---

## Task 4: `Groups.admin_regenerate_code`

**Files:**
- Modify: `lib/rule_maven/groups.ex:347-367` (`regenerate_code/2`)
- Test: `test/rule_maven/groups_test.exs`

**Interfaces:**
- Consumes: `@group_lock_class`, `generate_code/0` (existing)
- Produces: `Groups.admin_regenerate_code/1 :: (Group.t()) -> Group.t()`

- [ ] **Step 1: Write the failing test**

Add to `test/rule_maven/groups_test.exs`:

```elixir
  test "admin_regenerate_code rotates the code without membership" do
    owner = create_user("adminregen_owner")
    {:ok, group} = Groups.create_group(owner, %{name: "Regen Crew"})
    old_code = group.invite_code

    updated = Groups.admin_regenerate_code(group)
    assert updated.invite_code != old_code
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/groups_test.exs -v`
Expected: FAIL with `undefined function admin_regenerate_code/1`

- [ ] **Step 3: Implement**

Replace `regenerate_code/2` in `lib/rule_maven/groups.ex`. `do_regenerate_code/1` returns the unwrapped `group` (it cannot fail — no changeset validation beyond the code's own generation); `regenerate_code/2` wraps that in `{:ok, _}` to preserve its existing public shape (`GroupLive.Show` already matches `{:ok, _group} -> ...`), while `admin_regenerate_code/1` returns the unwrapped group directly since it has no failure case to signal:

```elixir
  @doc """
  Rotates the group's invite code, immediately invalidating the old one
  (join_by_code looks up by exact code, so a stale code simply matches no
  group). Requires the actor to be at least an admin.
  """
  def regenerate_code(actor, group) do
    if role_at_least?(actor, group, :admin) do
      {:ok, do_regenerate_code(group)}
    else
      {:error, :forbidden}
    end
  end

  @doc "Same as `regenerate_code/2`, no membership check. Site-admin callers only."
  def admin_regenerate_code(%Group{} = group), do: do_regenerate_code(group)

  # Same critical section as `join_by_code/2` and `remove_member/3`: a
  # rotation that doesn't hold the lock can be straddled by a join that
  # already read the old code, which then lands anyway.
  defp do_regenerate_code(group) do
    {:ok, updated} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@group_lock_class, group.id])

        group
        |> Group.changeset(%{invite_code: generate_code()})
        |> Repo.update!()
      end)

    updated
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/groups_test.exs test/rule_maven_web/live/group_live/show_test.exs -v`
Expected: PASS (confirms the `regenerate_code/2` shape change didn't break `GroupLive.Show`)

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/groups.ex test/rule_maven/groups_test.exs
git commit -m "feat(groups): add admin_regenerate_code"
```

---

## Task 5: `Groups.admin_set_role`

**Files:**
- Modify: `lib/rule_maven/groups.ex:382-402` (`set_role/4`)
- Test: `test/rule_maven/groups_test.exs`

**Interfaces:**
- Consumes: `Membership.roles/0`, `Membership.changeset/2`
- Produces: `Groups.admin_set_role/3 :: (Group.t(), integer(), String.t() | atom()) -> {:ok, Membership.t()} | {:error, :not_member} | {:error, :last_owner} | {:error, :use_transfer_ownership} | {:error, :invalid_role}`

Note: the actor-gated `set_role/4` returns `{:error, :forbidden}` both for "not admin/owner" and for "role not in Membership.roles()" — collapsing a permission failure and a validation failure into the same atom. The admin path has no permission check, so `admin_set_role/3` must return a *different* atom for the validation failure so callers can tell "bad input" apart from "forbidden" (which no longer applies here). Use `:invalid_role`.

- [ ] **Step 1: Write the failing tests**

Add to `test/rule_maven/groups_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/groups_test.exs -v`
Expected: FAIL with `undefined function admin_set_role/3`

- [ ] **Step 3: Implement**

Replace `set_role/4` in `lib/rule_maven/groups.ex`:

```elixir
  @doc """
  Promotes or demotes `target_user_id`'s role in the group. Owner-only —
  admins cannot change roles, including their own.

  This function can never create or destroy an owner: it cannot touch a
  membership row that currently holds "owner" (use `transfer_ownership/3`
  to move ownership), and it cannot promote anyone to "owner" either.

  Returns `{:error, :forbidden}` if the actor isn't the owner or the
  requested role is invalid, `{:error, :not_member}` if the target doesn't
  belong to the group, `{:error, :last_owner}` if the target currently
  holds "owner", or `{:error, :use_transfer_ownership}` if the requested
  role is "owner".
  """
  def set_role(actor, group, target_user_id, role) do
    if role_at_least?(actor, group, :owner) do
      case do_set_role(group, target_user_id, role) do
        {:error, :invalid_role} -> {:error, :forbidden}
        other -> other
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Same as `set_role/4`, no membership/ownership check. Site-admin callers
  only. Returns `{:error, :invalid_role}` instead of `{:error, :forbidden}`
  for a role outside `Membership.roles()`, since there is no permission
  failure on this path — only a validation one.
  """
  def admin_set_role(group, target_user_id, role), do: do_set_role(group, target_user_id, role)

  defp do_set_role(group, target_user_id, role) do
    role = to_string(role)

    cond do
      role not in Membership.roles() ->
        {:error, :invalid_role}

      role == "owner" ->
        {:error, :use_transfer_ownership}

      true ->
        case Repo.get_by(Membership, group_id: group.id, user_id: target_user_id) do
          nil -> {:error, :not_member}
          %Membership{role: "owner"} -> {:error, :last_owner}
          membership -> membership |> Membership.changeset(%{role: role}) |> Repo.update()
        end
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/groups_test.exs test/rule_maven_web/live/group_live/show_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/groups.ex test/rule_maven/groups_test.exs
git commit -m "feat(groups): add admin_set_role"
```

---

## Task 6: `Groups.admin_transfer_ownership`

**Files:**
- Modify: `lib/rule_maven/groups.ex:432-476` (`transfer_ownership/3`)
- Test: `test/rule_maven/groups_test.exs`

**Interfaces:**
- Consumes: `@group_lock_class`
- Produces: `Groups.admin_transfer_ownership/2 :: (Group.t(), integer()) -> {:ok, Group.t()} | {:error, :not_member}`

The actor-gated version re-verifies the actor still holds "owner" *under the lock* (TOCTOU guard, see the existing doc comment). The admin path has no actor to re-verify — it just needs the current owner row to demote and the target row to promote, both read under the same lock for the same reason (no torn state between two concurrent admin calls).

- [ ] **Step 1: Write the failing tests**

Add to `test/rule_maven/groups_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/groups_test.exs -v`
Expected: FAIL with `undefined function admin_transfer_ownership/2`

- [ ] **Step 3: Implement**

Replace `transfer_ownership/3` in `lib/rule_maven/groups.ex`:

```elixir
  @doc """
  Transfers ownership of `group` from the current owner to
  `new_owner_user_id`. This is the ONLY sanctioned way to move ownership —
  `set_role/4` refuses to touch an owner row in either direction.

  Runs inside a single transaction, first taking a transaction-scoped
  advisory lock keyed on the group id (same pattern as `join_by_code/2`),
  THEN re-verifies authorization: the actor must still hold "owner" on this
  group at the moment the lock is held. The naive approach — checking
  `role_at_least?(actor, group, :owner)` before opening the transaction —
  is a TOCTOU: two concurrent transfers by the same owner can both pass
  that outer check (neither has committed yet), and the loser, once it
  gets the lock, would otherwise blindly re-derive "whoever currently
  holds role: owner" and demote whoever the winner just promoted — a
  second, unconsented transfer away from the actual current owner. Pinning
  the check to the actor's own row under the lock closes that race:
  the loser sees that role: "owner" no longer belongs to `actor` and
  rolls back `:forbidden` instead of acting.

  Demotes the current owner to "admin" and promotes the target to
  "owner", in that order, so the DB's partial unique index
  (`group_memberships_one_owner_index`, one "owner" row per group) is
  never transiently violated.

  Returns `{:ok, group}`, `{:error, :forbidden}` if the actor isn't (or
  is no longer) the owner, or `{:error, :not_member}` if the target
  doesn't belong to the group.
  """
  def transfer_ownership(actor, group, new_owner_user_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@group_lock_class, group.id])

      current_owner = Repo.get_by(Membership, group_id: group.id, role: "owner")

      if is_nil(current_owner) or current_owner.user_id != actor.id do
        Repo.rollback(:forbidden)
      else
        case do_transfer_ownership(group, current_owner, new_owner_user_id) do
          {:ok, group} -> group
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
  end

  @doc """
  Same as `transfer_ownership/3`, no membership/ownership check on the
  actor — the current owner is derived from the group itself. Site-admin
  callers only.
  """
  def admin_transfer_ownership(%Group{} = group, new_owner_user_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@group_lock_class, group.id])

      current_owner = Repo.get_by(Membership, group_id: group.id, role: "owner")

      case do_transfer_ownership(group, current_owner, new_owner_user_id) do
        {:ok, group} -> group
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Runs holding the group's advisory lock (both callers above take it
  # before calling in). `current_owner` is the membership row currently
  # holding role "owner" — may be nil in a pathological state, handled below.
  defp do_transfer_ownership(group, current_owner, new_owner_user_id) do
    case Repo.get_by(Membership, group_id: group.id, user_id: new_owner_user_id) do
      nil ->
        {:error, :not_member}

      target_membership ->
        if current_owner do
          current_owner
          |> Membership.changeset(%{role: "admin"})
          |> Repo.update!()
        end

        target_membership
        |> Membership.changeset(%{role: "owner"})
        |> Repo.update!()

        # `groups.owner_id` is a denormalized pointer that must
        # track whichever membership row holds role: "owner". Left
        # stale, it would keep referencing the OLD owner even
        # though they're now a mere admin — and since that column
        # is `null: false` while its FK is `on_delete: :nilify_all`,
        # deleting that former owner's account later would crash
        # on a not-null violation instead of leaving the group
        # (which they no longer own) untouched.
        updated =
          group
          |> Group.changeset(%{owner_id: new_owner_user_id})
          |> Repo.update!()

        {:ok, updated}
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/groups_test.exs test/rule_maven_web/live/group_live/show_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/groups.ex test/rule_maven/groups_test.exs
git commit -m "feat(groups): add admin_transfer_ownership"
```

---

## Task 7: `Groups.admin_remove_member`

**Files:**
- Modify: `lib/rule_maven/groups.ex:487-541` (`remove_member/3`)
- Test: `test/rule_maven/groups_test.exs`

**Interfaces:**
- Consumes: `@group_lock_class`, `generate_code/0`
- Produces: `Groups.admin_remove_member/2 :: (Group.t(), integer()) -> {:ok, :removed} | {:error, :cannot_remove_owner} | {:error, :not_member}`

- [ ] **Step 1: Write the failing tests**

Add to `test/rule_maven/groups_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/groups_test.exs -v`
Expected: FAIL with `undefined function admin_remove_member/2`

- [ ] **Step 3: Implement**

Replace `remove_member/3` in `lib/rule_maven/groups.ex`:

```elixir
  @doc """
  Removes `target_user_id` from the group. Requires the actor to be at
  least an admin. The owner can never be removed by anyone — the DB's
  partial unique index guarantees exactly one owner per group, and
  transferring ownership is the only sanctioned way to change that.

  Returns `{:ok, :removed}`, `{:error, :forbidden}`,
  `{:error, :cannot_remove_owner}`, or `{:error, :not_member}`.
  """
  def remove_member(actor, group, target_user_id) do
    cond do
      not role_at_least?(actor, group, :admin) ->
        {:error, :forbidden}

      # Removing yourself is `leave/2`, not `remove_member/3`. Without this an
      # admin could delete their OWN membership row here, after which the caller
      # holds a page for a group they are no longer in (role comes back nil).
      # Routing self-removal through leave/2 also keeps the owner-must-transfer
      # guard in one place.
      actor.id == target_user_id ->
        {:error, :use_leave}

      true ->
        do_remove_member(group, target_user_id)
    end
  end

  @doc """
  Same as `remove_member/3`, no membership check and no self-removal guard
  (a site admin removing another user's membership is never "leaving").
  Site-admin callers only.
  """
  def admin_remove_member(%Group{} = group, target_user_id) do
    do_remove_member(group, target_user_id)
  end

  defp do_remove_member(group, target_user_id) do
    case Repo.get_by(Membership, group_id: group.id, user_id: target_user_id) do
      nil ->
        {:error, :not_member}

      %Membership{role: "owner"} ->
        {:error, :cannot_remove_owner}

      membership ->
        # Rotate the invite code in the same breath. The invite URL is shown
        # to EVERY member, not just admins, so a removed member is holding a
        # working key to the door they were just shown out of: `join_by_code/2`
        # checks only that the code exists and the link is active, and there is
        # no blocklist. Deleting the membership row alone bought nothing — they
        # re-open the link and they are back in, with full feed access and no
        # signal to the admin, as many times as they like.
        #
        # Rotating costs the crew a re-share of the link; not rotating makes
        # removal decorative.
        #
        # Under the SAME advisory lock `join_by_code/2` takes. A lock only
        # serializes the transactions that TAKE it: the joiner re-reads the
        # code inside the lock, but if the remover doesn't hold it, the two
        # still interleave — the joiner reads the group (code still valid),
        # the removal commits (row deleted, code rotated), and the joiner's
        # `role_of` then sees no membership and re-inserts the row that was
        # just deleted. Removal is only durable if the remover is inside the
        # same critical section the joiner is racing against.
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@group_lock_class, group.id])

          Repo.delete!(membership)

          group
          |> Group.changeset(%{invite_code: generate_code()})
          |> Repo.update!()
        end)

        {:ok, :removed}
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/groups_test.exs test/rule_maven_web/live/group_live/show_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/groups.ex test/rule_maven/groups_test.exs
git commit -m "feat(groups): add admin_remove_member"
```

---

## Task 8: `Groups.admin_delete_group` and `Groups.list_all`

**Files:**
- Modify: `lib/rule_maven/groups.ex:575-585` (`delete_group/2`)
- Modify: `lib/rule_maven/groups.ex` (add `list_all/1` near `list_for_user/1`, around line 248-259)
- Test: `test/rule_maven/groups_test.exs`

**Interfaces:**
- Consumes: `retract_contributions/1` (existing private function)
- Produces:
  - `Groups.admin_delete_group/1 :: (Group.t()) -> {:ok, :deleted} | {:error, Ecto.Changeset.t()}`
  - `Groups.list_all/1 :: (String.t() | nil) -> [%{group: Group.t(), member_count: integer(), owner_username: String.t()}]` — used by Task 10

- [ ] **Step 1: Write the failing tests**

Add to `test/rule_maven/groups_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/groups_test.exs -v`
Expected: FAIL with `undefined function admin_delete_group/1` and `undefined function list_all/0`

- [ ] **Step 3: Implement**

Replace `delete_group/2` in `lib/rule_maven/groups.ex`:

```elixir
  @doc """
  Deletes the group and (via FK cascade) its memberships. Owner-only.

  Retracts the crew's contributions FIRST. `questions_log.group_id` is
  `on_delete: :nilify_all`, so deleting the group strips its rows of the only
  marker that says they came from a crew — while leaving the unscreened text in
  place. Anything that then asks "is this a crew row?" by looking at `group_id`
  gets the wrong answer, so the rows are closed here, while we can still find
  them, rather than left for a guard to misjudge later.
  """
  def delete_group(actor, group) do
    if role_at_least?(actor, group, :owner) do
      do_delete_group(group)
    else
      {:error, :forbidden}
    end
  end

  @doc "Same as `delete_group/2`, no membership check. Site-admin callers only."
  def admin_delete_group(%Group{} = group), do: do_delete_group(group)

  defp do_delete_group(group) do
    Repo.transaction(fn ->
      retract_contributions(group)
      Repo.delete!(group)
      :deleted
    end)
  end
```

Add `list_all/1` after `list_for_user/1` (around line 259) in `lib/rule_maven/groups.ex`:

```elixir
  @doc """
  Lists every group in the system, for admin browsing. Each row is a map
  with `:group`, `:member_count`, and `:owner_username`. Optionally
  filtered by a case-insensitive substring match on the group name.
  Ordered by name.
  """
  def list_all(search \\ nil) do
    query =
      from g in Group,
        join: owner in RuleMaven.Users.User,
        on: owner.id == g.owner_id,
        left_join: m in Membership,
        on: m.group_id == g.id,
        group_by: [g.id, owner.username],
        order_by: [asc: g.name],
        select: %{group: g, member_count: count(m.id), owner_username: owner.username}

    query =
      if search && String.trim(search) != "" do
        pattern = "%#{String.trim(search)}%"
        from [g, owner, m] in query, where: ilike(g.name, ^pattern)
      else
        query
      end

    Repo.all(query)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/groups_test.exs test/rule_maven_web/live/group_live/show_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/groups.ex test/rule_maven/groups_test.exs
git commit -m "feat(groups): add admin_delete_group and list_all"
```

---

## Task 9: Full regression check on `RuleMaven.Groups`

**Files:**
- None modified — verification only.

**Interfaces:**
- Consumes: everything from Tasks 1–8
- Produces: confidence that the `do_*` extraction changed no actor-gated behavior

- [ ] **Step 1: Run the full existing group test suite**

Run: `mix test test/rule_maven/groups_test.exs test/rule_maven/groups_manage_test.exs test/rule_maven/groups_join_test.exs test/rule_maven/groups/group_test.exs test/rule_maven_web/live/group_live/show_test.exs test/rule_maven_web/live/group_live/manage_test.exs -v`
Expected: PASS — every pre-existing test (not just the ones added in Tasks 1–8) still passes, confirming the `do_*` split didn't change actor-gated behavior.

- [ ] **Step 2: If anything fails, stop and fix before continuing**

Do not proceed to Task 10 with a red test here — the LiveViews built next depend on these functions being correct.

- [ ] **Step 3: Commit (only if fixes were needed)**

```bash
git add lib/rule_maven/groups.ex
git commit -m "fix(groups): correct regression from do_* extraction"
```

(Skip this step entirely if Step 1 passed clean — no commit needed for a pure verification task.)

---

## Task 10: Router + `AdminLive.Groups` (list/search page)

**Files:**
- Modify: `lib/rule_maven_web/router.ex` (add two routes near line 95, alongside the other `AdminLive.*` routes)
- Create: `lib/rule_maven_web/live/admin_live/groups.ex`
- Test: `test/rule_maven_web/live/admin_live/groups_test.exs`

**Interfaces:**
- Consumes: `Groups.list_all/1`, `Groups.admin_delete_group/1`, `Users.can?/2`, `Audit.log/3`
- Produces: `/admin/groups` route rendering a searchable table; row "View" link to `/admin/groups/:token` (built by Task 11); row "Delete" button.

- [ ] **Step 1: Add the routes**

In `lib/rule_maven_web/router.ex`, add these two lines immediately after the existing `live "/admin/users", AdminLive.Users, :index` line (around line 95):

```elixir
      live "/admin/groups", AdminLive.Groups, :index
      live "/admin/groups/:token", AdminLive.GroupShow, :show
```

- [ ] **Step 2: Write the failing test**

Create `test/rule_maven_web/live/admin_live/groups_test.exs`:

```elixir
defmodule RuleMavenWeb.AdminLive.GroupsTest do
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GroupsFixtures

  alias RuleMaven.{Audit, Groups, Users}

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      Users.create_user(
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

  defp create_admin(prefix) do
    user = create_user(prefix)
    {:ok, admin} = Users.update_user_role(user, "admin")
    admin
  end

  test "a non-admin is redirected away", %{conn: conn} do
    user = create_user("groupsidx_plain")
    assert {:error, {:live_redirect, %{to: "/"}}} = conn |> login(user) |> live(~p"/admin/groups")
  end

  test "an admin sees every group, including ones they don't belong to", %{conn: conn} do
    admin = create_admin("groupsidx_admin")
    owner = create_user("groupsidx_owner")
    group = group_fixture(owner, %{name: "Visible Crew"})

    {:ok, _view, html} = conn |> login(admin) |> live(~p"/admin/groups")

    assert html =~ "Visible Crew"
    assert html =~ owner.username
  end

  test "search filters the list by name", %{conn: conn} do
    admin = create_admin("groupsidx_search_admin")
    owner = create_user("groupsidx_search_owner")
    group_fixture(owner, %{name: "Findable Crew"})
    group_fixture(owner, %{name: "Other Crew"})

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/groups")

    html = view |> form("#groups-search", %{"search" => "Findable"}) |> render_change()

    assert html =~ "Findable Crew"
    refute html =~ "Other Crew"
  end

  test "an admin can delete a group they don't belong to, and it's audit-logged", %{conn: conn} do
    admin = create_admin("groupsidx_del_admin")
    owner = create_user("groupsidx_del_owner")
    group = group_fixture(owner, %{name: "Doomed Crew"})

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/groups")

    view |> element("[phx-click=delete_group][phx-value-id='#{group.id}']") |> render_click()

    assert Groups.get_group_by_token(Phoenix.Param.to_param(group)) == nil

    entries = Audit.list(action: "group.delete")
    assert Enum.any?(entries, &(&1.target_id == group.id and &1.actor_id == admin.id))
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/rule_maven_web/live/admin_live/groups_test.exs -v`
Expected: FAIL — `AdminLive.Groups` module doesn't exist yet (`(UndefinedFunctionError)` or router "no route" style failure)

- [ ] **Step 4: Implement `AdminLive.Groups`**

Create `lib/rule_maven_web/live/admin_live/groups.ex`:

```elixir
defmodule RuleMavenWeb.AdminLive.Groups do
  @moduledoc """
  Admin-wide group browser: every group in the system, searchable by name,
  with a link to the per-group admin detail page and a delete action. Any
  `Users.can?(user, :admin)` user gets full access — see
  `docs/superpowers/specs/2026-07-11-admin-group-management-design.md` for
  why this isn't split off to super-admin-only.
  """

  use RuleMavenWeb, :live_view

  alias RuleMaven.{Audit, Groups, Users}

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok, assign(socket, page_title: "Manage Groups", search: "", rows: Groups.list_all())}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to do that.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, assign(socket, search: search, rows: Groups.list_all(search))}
  end

  def handle_event("delete_group", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    case Enum.find(socket.assigns.rows, &(&1.group.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Group not found.")}

      %{group: group} ->
        case Groups.admin_delete_group(group) do
          {:ok, :deleted} ->
            Audit.log(socket.assigns.current_user, "group.delete",
              target_type: "group",
              target_id: group.id,
              target_label: group.name
            )

            {:noreply,
             socket
             |> assign(rows: Groups.list_all(socket.assigns.search))
             |> put_flash(:info, "#{group.name} deleted.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Couldn't delete #{group.name}.")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:56rem;margin:0 auto;padding:1.25rem 1.5rem">
      <.link navigate={~p"/admin"} class="back-link">&larr; Back to admin</.link>

      <h1 style="font-size:1.5rem;font-weight:700;margin:0.25rem 0 0.5rem">Manage Groups</h1>

      <form id="groups-search" phx-change="search" style="margin-bottom:0.75rem">
        <input
          type="text"
          name="search"
          value={@search}
          placeholder="Search by group name…"
          phx-debounce="300"
          style="width:100%;max-width:20rem;border:1px solid var(--border);border-radius:0.35rem;padding:0.4rem 0.6rem;font-size:0.8rem;background:var(--bg);color:var(--text)"
        />
      </form>

      <p style="font-size:0.75rem;color:var(--text-muted);margin:0 0 0.75rem">
        {length(@rows)} groups
      </p>

      <div style="overflow-x:auto;border:1px solid var(--border);border-radius:0.5rem">
        <table style="width:100%;border-collapse:collapse;font-size:0.8rem;table-layout:fixed">
          <colgroup>
            <col />
            <col style="width:9rem" />
            <col style="width:6rem" />
            <col style="width:6rem" />
            <col style="width:6rem" />
            <col style="width:9rem" />
          </colgroup>
          <thead>
            <tr style="background:var(--bg-subtle);text-align:left">
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">Name</th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">Owner</th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">
                Members
              </th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">
                Sharing
              </th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">
                Invite
              </th>
              <th style="padding:0.45rem 0.75rem;font-weight:600;color:var(--text-muted)">
                Actions
              </th>
            </tr>
          </thead>
          <tbody>
            <%= for %{group: group, member_count: count, owner_username: owner} <- @rows do %>
              <tr style="border-top:1px solid var(--border-subtle)">
                <td style="padding:0.45rem 0.75rem;font-weight:500;overflow:hidden">
                  <.link
                    navigate={~p"/admin/groups/#{group}"}
                    style="text-decoration:none;color:var(--text)"
                  >
                    {group.name}
                  </.link>
                </td>
                <td style="padding:0.45rem 0.75rem;color:var(--text-muted)">{owner}</td>
                <td style="padding:0.45rem 0.75rem">{count} / {group.member_cap}</td>
                <td style="padding:0.45rem 0.75rem">
                  {if group.contribute_to_community, do: "On", else: "Off"}
                </td>
                <td style="padding:0.45rem 0.75rem">
                  {if group.invite_active, do: "Active", else: "Off"}
                </td>
                <td style="padding:0.35rem 0.75rem">
                  <div style="display:flex;gap:0.35rem">
                    <.link navigate={~p"/admin/groups/#{group}"} class="btn-outline btn-xs">
                      View
                    </.link>
                    <button
                      type="button"
                      phx-click="delete_group"
                      phx-value-id={group.id}
                      data-confirm={"Delete #{group.name}? This can't be undone."}
                      class="btn-danger-outline btn-xs"
                    >
                      Delete
                    </button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/rule_maven_web/live/admin_live/groups_test.exs -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven_web/router.ex lib/rule_maven_web/live/admin_live/groups.ex test/rule_maven_web/live/admin_live/groups_test.exs
git commit -m "feat(admin): add group list/search page with delete"
```

---

## Task 11: `AdminLive.GroupShow` (detail page)

**Files:**
- Create: `lib/rule_maven_web/live/admin_live/group_show.ex`
- Test: `test/rule_maven_web/live/admin_live/group_show_test.exs`

**Interfaces:**
- Consumes: `Groups.get_group_by_token/1`, `Groups.list_members/1`, `Groups.role_of/2`, `Groups.admin_rename/2`, `Groups.admin_set_invite_active/2`, `Groups.admin_regenerate_code/1`, `Groups.admin_set_contribute/2`, `Groups.admin_set_role/3`, `Groups.admin_transfer_ownership/2`, `Groups.admin_remove_member/2`, `Groups.admin_delete_group/1`, `Audit.log/3`
- Produces: `/admin/groups/:token` page — nothing downstream depends on this module's internals.

- [ ] **Step 1: Write the failing tests**

Create `test/rule_maven_web/live/admin_live/group_show_test.exs`:

```elixir
defmodule RuleMavenWeb.AdminLive.GroupShowTest do
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GroupsFixtures

  alias RuleMaven.{Audit, Groups, Users}

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      Users.create_user(
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

  defp create_admin(prefix) do
    user = create_user(prefix)
    {:ok, admin} = Users.update_user_role(user, "admin")
    admin
  end

  test "a non-admin is redirected away", %{conn: conn} do
    user = create_user("gshow_plain")
    owner = create_user("gshow_owner0")
    group = group_fixture(owner)

    assert {:error, {:live_redirect, %{to: "/"}}} =
             conn |> login(user) |> live(~p"/admin/groups/#{group}")
  end

  test "an unknown token redirects to the groups list", %{conn: conn} do
    admin = create_admin("gshow_unknown_admin")

    {:ok, _view, _html} =
      conn
      |> login(admin)
      |> live(~p"/admin/groups/not-a-real-token")
      |> follow_redirect(conn, ~p"/admin/groups")
  end

  test "admin can view a group they are not a member of, and sees an admin-view banner", %{
    conn: conn
  } do
    admin = create_admin("gshow_view_admin")
    owner = create_user("gshow_view_owner")
    group = group_fixture(owner, %{name: "Viewable Crew"})

    {:ok, _view, html} = conn |> login(admin) |> live(~p"/admin/groups/#{group}")

    assert html =~ "Viewable Crew"
    assert html =~ owner.username
    assert html =~ "Admin view"
  end

  test "admin can rename a group they are not a member of", %{conn: conn} do
    admin = create_admin("gshow_rename_admin")
    owner = create_user("gshow_rename_owner")
    group = group_fixture(owner, %{name: "Old Crew Name"})

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/groups/#{group}")

    view
    |> form("#admin-rename-group", group: %{name: "New Crew Name"})
    |> render_submit()

    assert Groups.get_group_by_token(Phoenix.Param.to_param(group)).name == "New Crew Name"

    entries = Audit.list(action: "group.rename")
    assert Enum.any?(entries, &(&1.target_id == group.id and &1.actor_id == admin.id))
  end

  test "admin can remove a member without being in the group", %{conn: conn} do
    admin = create_admin("gshow_remove_admin")
    owner = create_user("gshow_remove_owner")
    group = group_fixture(owner)
    member = create_user("gshow_remove_member")
    {:ok, _} = Groups.join_by_code(member, group.invite_code)

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/groups/#{group}")

    view
    |> element("[phx-click=remove_member][phx-value-user_id='#{member.id}']")
    |> render_click()

    refute Groups.member?(member, group)

    entries = Audit.list(action: "group.remove_member")
    assert Enum.any?(entries, &(&1.target_id == group.id and &1.actor_id == admin.id))
  end

  test "admin can transfer ownership without being in the group", %{conn: conn} do
    admin = create_admin("gshow_transfer_admin")
    owner = create_user("gshow_transfer_owner")
    group = group_fixture(owner)
    member = create_user("gshow_transfer_member")
    {:ok, _} = Groups.join_by_code(member, group.invite_code)

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/groups/#{group}")

    view
    |> element("[phx-click=transfer_ownership][phx-value-user_id='#{member.id}']")
    |> render_click()

    updated = Groups.get_group_by_token(Phoenix.Param.to_param(group))
    assert Groups.role_of(member, updated) == "owner"

    entries = Audit.list(action: "group.transfer_ownership")
    assert Enum.any?(entries, &(&1.target_id == group.id and &1.actor_id == admin.id))
  end

  test "admin can delete a group and is redirected to the groups list", %{conn: conn} do
    admin = create_admin("gshow_delete_admin")
    owner = create_user("gshow_delete_owner")
    group = group_fixture(owner, %{name: "Deletable Crew"})

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/groups/#{group}")

    {:ok, _view, html} =
      view
      |> element("[phx-click=delete_group]")
      |> render_click()
      |> follow_redirect(conn, ~p"/admin/groups")

    assert html =~ "deleted"
    assert Groups.get_group_by_token(Phoenix.Param.to_param(group)) == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven_web/live/admin_live/group_show_test.exs -v`
Expected: FAIL — `AdminLive.GroupShow` module doesn't exist yet

- [ ] **Step 3: Implement `AdminLive.GroupShow`**

Create `lib/rule_maven_web/live/admin_live/group_show.ex`:

```elixir
defmodule RuleMavenWeb.AdminLive.GroupShow do
  @moduledoc """
  Per-group admin detail page. Every control here calls the `admin_*`
  functions on `RuleMaven.Groups` — no membership or in-group role is
  required of the acting admin, unlike `RuleMavenWeb.GroupLive.Show` (the
  member-facing settings page this UI is adapted from). Every mutation is
  audit-logged (`target_type: "group"`).
  """

  use RuleMavenWeb, :live_view

  alias RuleMaven.{Audit, Groups, Users}

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      case Groups.get_group_by_token(token) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "That group doesn't exist.")
           |> push_navigate(to: ~p"/admin/groups")}

        group ->
          {:ok, socket |> assign(page_title: group.name, group: group) |> load_group()}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to do that.")
       |> push_navigate(to: ~p"/")}
    end
  end

  defp load_group(socket) do
    group = Groups.get_group_by_token(Phoenix.Param.to_param(socket.assigns.group))
    owner_membership = Enum.find(Groups.list_members(group), &(&1.role == "owner"))

    assign(socket,
      group: group,
      members: Groups.list_members(group),
      owner_username: owner_membership && owner_membership.username,
      viewer_role: Groups.role_of(socket.assigns.current_user, group),
      rename_form: to_form(%{"name" => group.name}, as: :group)
    )
  end

  # --- Rename --------------------------------------------------------------

  def handle_event("rename", %{"group" => %{"name" => name}}, socket) do
    group = socket.assigns.group

    case Groups.admin_rename(group, name) do
      {:ok, _group} ->
        audit(socket, "group.rename", group, %{name: name})
        {:noreply, socket |> put_flash(:info, "Group renamed.") |> load_group()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, rename_form: to_form(changeset, as: :group))}
    end
  end

  # --- Invite link -----------------------------------------------------------

  def handle_event("regenerate_code", _params, socket) do
    group = socket.assigns.group
    Groups.admin_regenerate_code(group)
    audit(socket, "group.regenerate_code", group, %{})
    {:noreply, socket |> put_flash(:info, "Invite link regenerated.") |> load_group()}
  end

  def handle_event("toggle_invite", _params, socket) do
    group = socket.assigns.group
    active? = !group.invite_active

    case Groups.admin_set_invite_active(group, active?) do
      {:ok, _group} ->
        audit(socket, "group.toggle_invite", group, %{active: active?})
        {:noreply, load_group(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't change the invite link.")}
    end
  end

  # --- Community contribution -------------------------------------------------

  def handle_event("toggle_contribute", _params, socket) do
    group = socket.assigns.group
    contribute? = !group.contribute_to_community

    case Groups.admin_set_contribute(group, contribute?) do
      {:ok, _group} ->
        audit(socket, "group.set_contribute", group, %{contribute: contribute?})
        {:noreply, load_group(socket)}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Couldn't change the community contribution setting."
         )}
    end
  end

  # --- Member cap --------------------------------------------------------

  def handle_event("set_member_cap", %{"member_cap" => cap_str}, socket) do
    group = socket.assigns.group

    with {cap, ""} <- Integer.parse(cap_str),
         {:ok, _group} <- Groups.admin_set_member_cap(group, cap) do
      audit(socket, "group.set_member_cap", group, %{cap: cap})
      {:noreply, socket |> put_flash(:info, "Member cap updated.") |> load_group()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Enter a whole number greater than zero.")}
    end
  end

  # --- Roles ---------------------------------------------------------------

  def handle_event("set_role", %{"user_id" => user_id, "role" => role}, socket) do
    group = socket.assigns.group

    with {:ok, id} <- parse_user_id(user_id),
         {:ok, _membership} <- Groups.admin_set_role(group, id, role) do
      audit(socket, "group.set_role", group, %{user_id: id, role: role})
      {:noreply, load_group(socket)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("transfer_ownership", %{"user_id" => user_id}, socket) do
    group = socket.assigns.group

    with {:ok, id} <- parse_user_id(user_id),
         {:ok, _group} <- Groups.admin_transfer_ownership(group, id) do
      audit(socket, "group.transfer_ownership", group, %{new_owner_id: id})
      {:noreply, socket |> put_flash(:info, "Ownership transferred.") |> load_group()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  # --- Membership ------------------------------------------------------------

  def handle_event("remove_member", %{"user_id" => user_id}, socket) do
    group = socket.assigns.group

    with {:ok, id} <- parse_user_id(user_id),
         {:ok, :removed} <- Groups.admin_remove_member(group, id) do
      audit(socket, "group.remove_member", group, %{user_id: id})

      {:noreply,
       socket
       |> put_flash(:info, "Member removed. The invite link has been reset.")
       |> load_group()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("delete_group", _params, socket) do
    group = socket.assigns.group

    case Groups.admin_delete_group(group) do
      {:ok, :deleted} ->
        audit(socket, "group.delete", group, %{})

        {:noreply,
         socket
         |> put_flash(:info, "#{group.name} was deleted.")
         |> push_navigate(to: ~p"/admin/groups")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't delete #{group.name}.")}
    end
  end

  defp audit(socket, action, group, metadata) do
    Audit.log(socket.assigns.current_user, action,
      target_type: "group",
      target_id: group.id,
      target_label: group.name,
      metadata: metadata
    )
  end

  defp parse_user_id(user_id) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {id, ""} -> {:ok, id}
      _ -> {:error, :not_member}
    end
  end

  defp parse_user_id(_), do: {:error, :not_member}

  defp error_message(:not_member), do: "That person isn't a member of this group."
  defp error_message(:last_owner), do: "The group's owner can't be demoted directly."
  defp error_message(:cannot_remove_owner), do: "The group's owner can't be removed."
  defp error_message(:invalid_role), do: "That isn't a valid role."

  defp error_message(:use_transfer_ownership),
    do: "Use \"Make owner\" to transfer ownership instead."

  defp error_message(other), do: "Something went wrong (#{other})."

  defp invite_url(group), do: url(~p"/groups/join/#{group.invite_code}")

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width:40rem;margin:0 auto;padding:1.25rem 1rem">
      <.link navigate={~p"/admin/groups"} class="back-link">&larr; All groups</.link>

      <div style="display:flex;align-items:center;justify-content:space-between;gap:0.5rem;flex-wrap:wrap;margin:0.5rem 0 0.25rem">
        <h1 style="font-size:1.25rem;font-weight:800;margin:0">{@group.name}</h1>
      </div>
      <p style="font-size:0.85rem;color:var(--text-muted);margin:0 0 0.5rem 0">
        Owner: <strong>{@owner_username}</strong>
      </p>

      <div
        :if={is_nil(@viewer_role)}
        style="padding:0.5rem 0.75rem;margin-bottom:1.25rem;border-radius:0.5rem;border:1px solid var(--accent);background:var(--bg-surface);font-size:0.78rem;color:var(--text)"
      >
        Admin view — you are not a member of this group. Every control below acts
        on the group directly.
      </div>

      <!-- Invite link -->
      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Invite link</h2>
        <p style="font-size:0.8rem;color:var(--text-muted);margin:0 0 0.6rem 0">
          <%= if @group.invite_active do %>
            Currently <strong style="color:var(--green)">active</strong>.
          <% else %>
            Currently <strong style="color:var(--text-muted)">off</strong> — new joins are blocked.
          <% end %>
        </p>
        <div style="display:flex;gap:0.5rem;flex-wrap:wrap;align-items:center">
          <input
            type="text"
            readonly
            value={invite_url(@group)}
            id="invite-url"
            onclick="this.select()"
            style="flex:1;min-width:12rem;padding:0.45rem 0.6rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg);color:var(--text);font-size:0.8rem"
          />
          <button
            type="button"
            phx-click="regenerate_code"
            data-confirm="Regenerate the invite link? The old link will stop working."
            class="btn-sm"
          >
            Regenerate
          </button>
          <button type="button" phx-click="toggle_invite" class="btn-sm">
            {if @group.invite_active, do: "Turn off invite", else: "Turn on invite"}
          </button>
        </div>
      </section>

      <!-- Members -->
      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">
          Members ({length(@members)})
        </h2>
        <ul style="list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:0.5rem">
          <li
            :for={m <- @members}
            style="display:flex;align-items:center;justify-content:space-between;gap:0.5rem;flex-wrap:wrap;padding:0.5rem 0;border-bottom:1px solid var(--border-subtle,var(--border))"
          >
            <div style="display:flex;align-items:center;gap:0.5rem;min-width:0">
              <span style="font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">
                {m.username}
              </span>
              <span style="font-size:0.7rem;font-weight:700;border-radius:999px;padding:0.1rem 0.5rem;background:var(--bg-subtle);color:var(--text)">
                {String.capitalize(m.role)}
              </span>
            </div>
            <div style="display:flex;gap:0.4rem;flex-wrap:wrap">
              <button
                :if={m.role == "member"}
                type="button"
                phx-click="set_role"
                phx-value-user_id={m.user_id}
                phx-value-role="admin"
                class="btn-xs"
              >
                Make admin
              </button>
              <button
                :if={m.role == "admin"}
                type="button"
                phx-click="set_role"
                phx-value-user_id={m.user_id}
                phx-value-role="member"
                class="btn-xs"
              >
                Remove admin
              </button>
              <button
                :if={m.role != "owner"}
                type="button"
                phx-click="transfer_ownership"
                phx-value-user_id={m.user_id}
                data-confirm={"Make #{m.username} the owner?"}
                class="btn-xs"
              >
                Make owner
              </button>
              <button
                :if={m.role != "owner"}
                type="button"
                phx-click="remove_member"
                phx-value-user_id={m.user_id}
                data-confirm={"Remove #{m.username} from #{@group.name}?\n\nThis also resets the invite link."}
                class="btn-danger-outline btn-xs"
              >
                Remove
              </button>
            </div>
          </li>
        </ul>
      </section>

      <!-- Member cap -->
      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Member cap</h2>
        <form
          id="admin-set-cap"
          phx-submit="set_member_cap"
          style="display:flex;gap:0.5rem;flex-wrap:wrap"
        >
          <input
            type="number"
            name="member_cap"
            value={@group.member_cap}
            min="1"
            style="width:6rem;padding:0.45rem 0.6rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg);color:var(--text);font-size:0.85rem"
          />
          <button type="submit" class="btn-sm">Save</button>
        </form>
      </section>

      <!-- Community contribution -->
      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Community sharing</h2>
        <label for="admin-contribute-toggle" class="crew-toggle">
          <input
            type="checkbox"
            id="admin-contribute-toggle"
            phx-click="toggle_contribute"
            checked={@group.contribute_to_community}
          />
          <span class="crew-toggle__text">
            <span class="crew-toggle__label">Contribute answers to the community</span>
          </span>
        </label>
      </section>

      <!-- Rename -->
      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface);margin-bottom:1.25rem">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Rename group</h2>
        <.form
          for={@rename_form}
          id="admin-rename-group"
          phx-submit="rename"
          style="display:flex;gap:0.5rem;flex-wrap:wrap"
        >
          <input
            type="text"
            name="group[name]"
            value={@rename_form[:name].value}
            maxlength="60"
            required
            style="flex:1;min-width:12rem;padding:0.45rem 0.6rem;border:1px solid var(--border);border-radius:0.5rem;background:var(--bg);color:var(--text);font-size:0.85rem"
          />
          <button type="submit" class="btn-sm">Rename</button>
        </.form>
      </section>

      <!-- Danger zone -->
      <section style="border:1px solid var(--border);border-radius:0.75rem;padding:1rem 1.25rem;background:var(--bg-surface)">
        <h2 style="font-size:0.95rem;font-weight:700;margin:0 0 0.6rem 0">Danger zone</h2>
        <button
          type="button"
          phx-click="delete_group"
          data-confirm={"Delete #{@group.name}? This can't be undone."}
          class="btn-danger btn-sm"
        >
          Delete group
        </button>
      </section>
    </div>
    """
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven_web/live/admin_live/group_show_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven_web/live/admin_live/group_show.ex test/rule_maven_web/live/admin_live/group_show_test.exs
git commit -m "feat(admin): add per-group admin detail page with full control"
```

---

## Task 12: Add "Groups" card to `AdminLive.Index`

**Files:**
- Modify: `lib/rule_maven_web/live/admin_live/index.ex:336-361` (the "Manage" section)
- Test: `test/rule_maven_web/live/admin_live/index_super_admin_cards_test.exs` (extend) or a new focused test

**Interfaces:**
- Consumes: nothing new
- Produces: nothing consumed downstream — final integration point.

- [ ] **Step 1: Write the failing test**

Create `test/rule_maven_web/live/admin_live/groups_card_test.exs`:

```elixir
defmodule RuleMavenWeb.AdminLive.GroupsCardTest do
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RuleMaven.Users

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_admin(prefix) do
    {:ok, user} =
      Users.create_user(%{
        username: "#{prefix}_user",
        email: "#{prefix}_user@test.com",
        password: "password1234"
      })

    {:ok, admin} = Users.update_user_role(user, "admin")
    admin
  end

  test "the admin dashboard links to /admin/groups", %{conn: conn} do
    admin = create_admin("idxcard")

    {:ok, _view, html} = conn |> login(admin) |> live(~p"/admin")

    assert html =~ ~s(href="/admin/groups")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven_web/live/admin_live/groups_card_test.exs -v`
Expected: FAIL — no `/admin/groups` link on the page yet

- [ ] **Step 3: Add the card**

In `lib/rule_maven_web/live/admin_live/index.ex`, inside the `<.section title="Manage">` block (around line 336-361), add a new `<.card>` after the "Manage Users" card:

```elixir
        <.card
          navigate={~p"/admin/groups"}
          icon="🧑‍🤝‍🧑"
          title="Manage Groups"
          desc="View every crew, manage members, rename or delete."
        />
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven_web/live/admin_live/groups_card_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven_web/live/admin_live/index.ex test/rule_maven_web/live/admin_live/groups_card_test.exs
git commit -m "feat(admin): link Manage Groups card from admin dashboard"
```

---

## Task 13: Full suite check

**Files:** None — verification only.

- [ ] **Step 1: Run every test file touched or added by this plan**

Run:
```bash
mix test \
  test/rule_maven/groups_test.exs \
  test/rule_maven/groups_manage_test.exs \
  test/rule_maven/groups_join_test.exs \
  test/rule_maven/groups/group_test.exs \
  test/rule_maven_web/live/group_live/show_test.exs \
  test/rule_maven_web/live/group_live/manage_test.exs \
  test/rule_maven_web/live/admin_live/groups_test.exs \
  test/rule_maven_web/live/admin_live/group_show_test.exs \
  test/rule_maven_web/live/admin_live/groups_card_test.exs \
  test/rule_maven_web/live/admin_live/index_super_admin_cards_test.exs \
  -v
```
Expected: PASS, zero failures.

- [ ] **Step 2: Run `mix compile --warnings-as-errors`**

Run: `mix compile --warnings-as-errors`
Expected: clean compile, zero warnings (per project hard rule — see memory `zero-warnings-zero-failures`).

- [ ] **Step 3: No commit needed** — this is a verification-only task. If Step 1 or Step 2 finds anything, fix it and commit under the fix, not here.
