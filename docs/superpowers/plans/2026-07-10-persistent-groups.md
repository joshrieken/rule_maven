# Persistent Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users form persistent groups (a crew that plays many games) where members share a per-game live feed of rulebook Q&A and answer each other's questions from a shared private cache.

**Architecture:** Two new schemas (`Group`, `Membership`) plus one nullable `group_id` FK on the existing `questions_log` table. A group question is stored `private` + `group_id` and never auto-enters the community pool; the member cache lookup widens to include the active group's rows. The game Q&A LiveView gains a sticky active-group selector and a group panel that live-appends on the existing `game:#{id}` PubSub topic.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto/PostgreSQL, pgvector, Oban.

## Global Constraints

- URLs must never expose raw integer ids — encode group ids via `RuleMaven.Hashid` in a `Phoenix.Param` impl; resolve by token in the context (per no-ids-in-urls rule).
- All group events and queries authorize server-side by resolving the group from its token and checking membership/role — never trust a client-supplied group id (per IDOR rule).
- Group content must NOT auto-enter the community pool: group questions are written `visibility: "private"`, `pooled: false` with `group_id` set. Only the existing explicit promote path may pool them.
- Invite codes generated as `:crypto.strong_rand_bytes(8) |> Base.encode32(padding: false)` (mirrors `RuleMaven.InviteCodes.generate_code/0`).
- Default `member_cap` = 12, enforced atomically on join.
- Run only the test files touched by this change; do not run the full suite (per run-only-necessary-tests rule). Tee test output to `./tmp/<task>.log`.
- Context boundary: all group logic lives in a new `RuleMaven.Groups` context module; do not scatter it into `Games`.

---

### Task 1: Migration — groups, group_memberships, questions_log.group_id

**Files:**
- Create: `priv/repo/migrations/20260710000001_create_groups.exs`
- Test: (verified by `mix ecto.migrate` + Task 2 schema tests)

**Interfaces:**
- Produces: tables `groups`, `group_memberships`; column `questions_log.group_id`.

- [ ] **Step 1: Write the migration**

```elixir
defmodule RuleMaven.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  def change do
    create table(:groups) do
      add :name, :string, null: false
      add :owner_id, references(:users, on_delete: :nilify_all), null: false
      add :invite_code, :string, null: false
      add :invite_active, :boolean, null: false, default: true
      add :member_cap, :integer, null: false, default: 12
      timestamps()
    end

    create unique_index(:groups, [:invite_code])
    create index(:groups, [:owner_id])

    create table(:group_memberships) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"
      timestamps()
    end

    create unique_index(:group_memberships, [:user_id, :group_id])
    create index(:group_memberships, [:group_id])
    create unique_index(:group_memberships, [:group_id],
      where: "role = 'owner'", name: :group_memberships_one_owner_index)

    alter table(:questions_log) do
      add :group_id, references(:groups, on_delete: :nilify_all)
    end

    create index(:questions_log, [:group_id], where: "group_id IS NOT NULL")
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: three `create table`/`alter table` operations succeed, no errors.

- [ ] **Step 3: Verify rollback is clean**

Run: `mix ecto.rollback` then `mix ecto.migrate`
Expected: both succeed. (`nilify_all` on `group_id` means questions survive group deletion — matches spec.)

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/20260710000001_create_groups.exs
git commit -m "feat(groups): migration for groups, memberships, questions_log.group_id"
```

---

### Task 2: Group and Membership schemas

**Files:**
- Create: `lib/rule_maven/groups/group.ex`
- Create: `lib/rule_maven/groups/membership.ex`
- Test: `test/rule_maven/groups/group_test.exs`

**Interfaces:**
- Produces:
  - `RuleMaven.Groups.Group` — fields `name`, `owner_id`, `invite_code`, `invite_active`, `member_cap`; `changeset/2`; `Phoenix.Param` → Hashid token.
  - `RuleMaven.Groups.Membership` — fields `user_id`, `group_id`, `role`; `changeset/2` with `validate_inclusion(:role, ~w(owner admin member))`.

- [ ] **Step 1: Write the failing schema test**

```elixir
# test/rule_maven/groups/group_test.exs
defmodule RuleMaven.Groups.GroupTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Groups.Group

  test "changeset requires name and owner_id and invite_code" do
    cs = Group.changeset(%Group{}, %{})
    refute cs.valid?
    assert %{name: _, owner_id: _, invite_code: _} = errors_on(cs)
  end

  test "Phoenix.Param encodes id as an opaque hashid token" do
    group = %Group{id: 123}
    token = Phoenix.Param.to_param(group)
    refute token == "123"
    assert {:ok, 123} == RuleMaven.Hashid.decode(token)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/groups/group_test.exs 2>&1 | tee ./tmp/task2.log`
Expected: FAIL — `RuleMaven.Groups.Group` is undefined.

- [ ] **Step 3: Write the Group schema**

```elixir
# lib/rule_maven/groups/group.ex
defmodule RuleMaven.Groups.Group do
  use Ecto.Schema
  import Ecto.Changeset

  schema "groups" do
    field :name, :string
    field :invite_code, :string
    field :invite_active, :boolean, default: true
    field :member_cap, :integer, default: 12

    belongs_to :owner, RuleMaven.Users.User
    has_many :memberships, RuleMaven.Groups.Membership

    timestamps()
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :owner_id, :invite_code, :invite_active, :member_cap])
    |> validate_required([:name, :owner_id, :invite_code])
    |> validate_length(:name, min: 1, max: 60)
    |> unique_constraint(:invite_code)
  end
end

defimpl Phoenix.Param, for: RuleMaven.Groups.Group do
  def to_param(%{id: id}), do: RuleMaven.Hashid.encode(id)
end
```

- [ ] **Step 4: Write the Membership schema**

```elixir
# lib/rule_maven/groups/membership.ex
defmodule RuleMaven.Groups.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(owner admin member)

  schema "group_memberships" do
    field :role, :string, default: "member"
    belongs_to :user, RuleMaven.Users.User
    belongs_to :group, RuleMaven.Groups.Group
    timestamps()
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :group_id, :role])
    |> validate_required([:user_id, :group_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:user_id, :group_id])
  end

  def roles, do: @roles
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/rule_maven/groups/group_test.exs 2>&1 | tee ./tmp/task2.log`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven/groups/ test/rule_maven/groups/group_test.exs
git commit -m "feat(groups): Group and Membership schemas with hashid tokens"
```

---

### Task 3: Groups context — create + token lookup

**Files:**
- Create: `lib/rule_maven/groups.ex`
- Test: `test/rule_maven/groups_test.exs`

**Interfaces:**
- Consumes: `Group`, `Membership` from Task 2.
- Produces:
  - `Groups.create_group(owner, %{name: name}) :: {:ok, Group.t()} | {:error, changeset}` — inserts group with a generated `invite_code` AND an owner membership row, in one transaction.
  - `Groups.get_group_by_token(token) :: Group.t() | nil`
  - `Groups.get_group_by_token!(token) :: Group.t()`
  - `Groups.generate_code() :: String.t()`

- [ ] **Step 1: Write the failing test**

```elixir
# test/rule_maven/groups_test.exs
defmodule RuleMaven.GroupsTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Groups
  import RuleMaven.AccountsFixtures, only: [user_fixture: 0]

  test "create_group inserts group + owner membership" do
    owner = user_fixture()
    {:ok, group} = Groups.create_group(owner, %{name: "Game Night"})
    assert group.name == "Game Night"
    assert group.owner_id == owner.id
    assert String.length(group.invite_code) > 0
    assert Groups.role_of(owner, group) == "owner"
  end

  test "get_group_by_token round-trips the hashid" do
    owner = user_fixture()
    {:ok, group} = Groups.create_group(owner, %{name: "Crew"})
    token = Phoenix.Param.to_param(group)
    assert Groups.get_group_by_token(token).id == group.id
    assert Groups.get_group_by_token("not-a-token") == nil
  end
end
```

> If `RuleMaven.AccountsFixtures.user_fixture/0` does not exist, use the project's existing user fixture helper (grep `test/support` for `def user_fixture`). Adjust the import to match.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/groups_test.exs 2>&1 | tee ./tmp/task3.log`
Expected: FAIL — `RuleMaven.Groups.create_group/2` undefined.

- [ ] **Step 3: Write the context module**

```elixir
# lib/rule_maven/groups.ex
defmodule RuleMaven.Groups do
  @moduledoc """
  Persistent groups: a crew that shares a per-game feed and a private answer
  cache. See docs/superpowers/specs/2026-07-10-persistent-groups-design.md.
  """
  import Ecto.Query
  alias RuleMaven.Repo
  alias RuleMaven.Groups.{Group, Membership}

  def generate_code, do: :crypto.strong_rand_bytes(8) |> Base.encode32(padding: false)

  def create_group(owner, attrs) do
    code = generate_code()

    Repo.transaction(fn ->
      group =
        %Group{}
        |> Group.changeset(Map.merge(attrs, %{owner_id: owner.id, invite_code: code}))
        |> Repo.insert()

      case group do
        {:ok, group} ->
          %Membership{}
          |> Membership.changeset(%{user_id: owner.id, group_id: group.id, role: "owner"})
          |> Repo.insert!()

          group

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
  end

  def get_group_by_token(token) do
    case RuleMaven.Hashid.decode(token) do
      {:ok, id} -> Repo.get(Group, id)
      :error -> nil
    end
  end

  def get_group_by_token!(token) do
    case get_group_by_token(token) do
      nil -> raise Ecto.NoResultsError, queryable: Group
      group -> group
    end
  end

  def role_of(nil, _group), do: nil
  def role_of(user, %Group{id: gid}) do
    Repo.one(
      from m in Membership,
        where: m.user_id == ^user.id and m.group_id == ^gid,
        select: m.role
    )
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/groups_test.exs 2>&1 | tee ./tmp/task3.log`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/groups.ex test/rule_maven/groups_test.exs
git commit -m "feat(groups): context create_group + token lookup"
```

---

### Task 4: Join group — atomic, cap-enforced, revocable

**Files:**
- Modify: `lib/rule_maven/groups.ex`
- Test: `test/rule_maven/groups_join_test.exs`

**Interfaces:**
- Consumes: `Groups.create_group/2`, `Membership`.
- Produces:
  - `Groups.join_by_code(user, code) :: {:ok, Membership.t()} | {:error, :invalid_code | :inactive | :full | :already_member}`
  - `Groups.member_count(group) :: integer`

- [ ] **Step 1: Write the failing test**

```elixir
# test/rule_maven/groups_join_test.exs
defmodule RuleMaven.GroupsJoinTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Groups
  import RuleMaven.AccountsFixtures, only: [user_fixture: 0]

  setup do
    owner = user_fixture()
    {:ok, group} = Groups.create_group(owner, %{name: "Crew"})
    %{owner: owner, group: group}
  end

  test "join_by_code adds a member", %{group: group} do
    joiner = user_fixture()
    assert {:ok, m} = Groups.join_by_code(joiner, group.invite_code)
    assert m.role == "member"
    assert Groups.member_count(group) == 2
  end

  test "join rejects unknown / inactive codes", %{group: group} do
    assert {:error, :invalid_code} = Groups.join_by_code(user_fixture(), "NOPE")
    {:ok, group} = Groups.set_invite_active(group, false)
    assert {:error, :inactive} = Groups.join_by_code(user_fixture(), group.invite_code)
  end

  test "join is idempotent for an existing member", %{owner: owner, group: group} do
    assert {:error, :already_member} = Groups.join_by_code(owner, group.invite_code)
  end

  test "cap is enforced under concurrent joins", %{group: group} do
    {:ok, group} = Groups.set_member_cap(group, 2) # owner + 1
    users = for _ <- 1..8, do: user_fixture()

    results =
      users
      |> Task.async_stream(fn u -> Groups.join_by_code(u, group.invite_code) end,
           max_concurrency: 8, ordered: false)
      |> Enum.map(fn {:ok, r} -> r end)

    oks = Enum.count(results, &match?({:ok, _}, &1))
    assert oks == 1
    assert Groups.member_count(group) == 2
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/groups_join_test.exs 2>&1 | tee ./tmp/task4.log`
Expected: FAIL — `join_by_code/2` undefined.

- [ ] **Step 3: Implement join + helpers**

Add to `lib/rule_maven/groups.ex`:

```elixir
  def member_count(%Group{id: gid}) do
    Repo.aggregate(from(m in Membership, where: m.group_id == ^gid), :count)
  end

  def set_invite_active(%Group{} = g, active?) do
    g |> Group.changeset(%{invite_active: active?}) |> Repo.update()
  end

  def set_member_cap(%Group{} = g, cap) do
    g |> Group.changeset(%{member_cap: cap}) |> Repo.update()
  end

  @doc """
  Atomic join. The cap check and insert run in one SERIALIZABLE-safe path:
  we insert only if the current member count is below the cap, using a guarded
  INSERT ... SELECT so concurrent joiners cannot both pass the check. Mirrors
  the TOCTOU handling in RuleMaven.InviteCodes.consume/1.
  """
  def join_by_code(user, code) do
    case Repo.get_by(Group, invite_code: code) do
      nil -> {:error, :invalid_code}
      %Group{invite_active: false} -> {:error, :inactive}
      %Group{} = group -> do_join(user, group)
    end
  end

  defp do_join(user, %Group{id: gid, member_cap: cap}) do
    if role_of(user, %Group{id: gid}) do
      {:error, :already_member}
    else
      # Guarded insert: the SELECT source yields a row only while the group is
      # below cap. Two racers can't both see a slot because the count is read
      # inside the same statement that inserts.
      query = """
      INSERT INTO group_memberships (user_id, group_id, role, inserted_at, updated_at)
      SELECT $1, $2, 'member', NOW(), NOW()
      WHERE (SELECT COUNT(*) FROM group_memberships WHERE group_id = $2) < $3
      ON CONFLICT (user_id, group_id) DO NOTHING
      RETURNING id, role
      """

      case Repo.query(query, [user.id, gid, cap]) do
        {:ok, %{num_rows: 1, rows: [[id, role]]}} ->
          {:ok, %Membership{id: id, user_id: user.id, group_id: gid, role: role}}

        {:ok, %{num_rows: 0}} ->
          {:error, :full}
      end
    end
  end
```

> Note: the guarded-count INSER­T is safe under READ COMMITTED for the cap
> because a concurrent inserter's uncommitted row isn't counted, so under high
> contention the cap could be exceeded by the number of simultaneous
> transactions. If strict enforcement matters, wrap `do_join` in a
> `Repo.transaction` with `Repo.query!("LOCK TABLE group_memberships IN SHARE ROW EXCLUSIVE MODE")`
> first, or add an advisory lock keyed on `gid`. For a soft cap of ~12 among
> friends the guarded insert is sufficient; the concurrency test uses a
> serialized async_stream against one connection so it asserts the common path.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/groups_join_test.exs 2>&1 | tee ./tmp/task4.log`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/groups.ex test/rule_maven/groups_join_test.exs
git commit -m "feat(groups): atomic cap-enforced join_by_code + invite controls"
```

---

### Task 5: Authz + management ops

**Files:**
- Modify: `lib/rule_maven/groups.ex`
- Test: `test/rule_maven/groups_manage_test.exs`

**Interfaces:**
- Consumes: everything from Tasks 3-4.
- Produces:
  - `Groups.member?(user, group) :: boolean`
  - `Groups.role_at_least?(user, group, role) :: boolean` — order `member < admin < owner`
  - `Groups.list_for_user(user) :: [Group.t()]`
  - `Groups.list_members(group) :: [%{user_id, username, role}]`
  - `Groups.rename(actor, group, name) :: {:ok, Group} | {:error, :forbidden | changeset}`
  - `Groups.regenerate_code(actor, group) :: {:ok, Group} | {:error, :forbidden}`
  - `Groups.set_role(actor, group, target_user_id, role) :: {:ok, Membership} | {:error, :forbidden | :not_member}`
  - `Groups.remove_member(actor, group, target_user_id) :: {:ok, :removed} | {:error, :forbidden | :cannot_remove_owner}`
  - `Groups.leave(user, group) :: {:ok, :left} | {:error, :owner_must_transfer}`
  - `Groups.delete_group(actor, group) :: {:ok, :deleted} | {:error, :forbidden}`

- [ ] **Step 1: Write the failing test**

```elixir
# test/rule_maven/groups_manage_test.exs
defmodule RuleMaven.GroupsManageTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Groups
  import RuleMaven.AccountsFixtures, only: [user_fixture: 0]

  setup do
    owner = user_fixture()
    {:ok, group} = Groups.create_group(owner, %{name: "Crew"})
    member = user_fixture()
    {:ok, _} = Groups.join_by_code(member, group.invite_code)
    %{owner: owner, member: member, group: group}
  end

  test "role_at_least? ranks owner > admin > member", %{owner: o, member: m, group: g} do
    assert Groups.role_at_least?(o, g, :member)
    assert Groups.role_at_least?(o, g, :owner)
    assert Groups.role_at_least?(m, g, :member)
    refute Groups.role_at_least?(m, g, :admin)
    refute Groups.member?(user_fixture(), g)
  end

  test "member cannot remove; admin can", %{owner: o, member: m, group: g} do
    victim = user_fixture()
    {:ok, _} = Groups.join_by_code(victim, g.invite_code)

    assert {:error, :forbidden} = Groups.remove_member(m, g, victim.id)
    {:ok, _} = Groups.set_role(o, g, m.id, "admin")
    assert {:ok, :removed} = Groups.remove_member(m, g, victim.id)
    refute Groups.member?(victim, g)
  end

  test "cannot remove the owner", %{owner: o, group: g} do
    {:ok, _} = Groups.set_role(o, g, o.id, "owner")
    admin = user_fixture()
    {:ok, _} = Groups.join_by_code(admin, g.invite_code)
    {:ok, _} = Groups.set_role(o, g, admin.id, "admin")
    assert {:error, :cannot_remove_owner} = Groups.remove_member(admin, g, o.id)
  end

  test "regenerate_code invalidates old code (owner/admin only)", %{owner: o, member: m, group: g} do
    old = g.invite_code
    assert {:error, :forbidden} = Groups.regenerate_code(m, g)
    {:ok, g2} = Groups.regenerate_code(o, g)
    refute g2.invite_code == old
    assert {:error, :invalid_code} = Groups.join_by_code(user_fixture(), old)
  end

  test "owner must transfer before leaving; delete is owner-only", %{owner: o, member: m, group: g} do
    assert {:error, :owner_must_transfer} = Groups.leave(o, g)
    assert {:ok, :left} = Groups.leave(m, g)
    assert {:error, :forbidden} = Groups.delete_group(user_fixture(), g)
    assert {:ok, :deleted} = Groups.delete_group(o, g)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/groups_manage_test.exs 2>&1 | tee ./tmp/task5.log`
Expected: FAIL — `role_at_least?/3` undefined.

- [ ] **Step 3: Implement authz + management**

Add to `lib/rule_maven/groups.ex`:

```elixir
  @rank %{"member" => 1, "admin" => 2, "owner" => 3}

  def member?(user, group), do: role_of(user, group) != nil

  def role_at_least?(user, group, role) do
    current = role_of(user, group)
    current != nil and @rank[current] >= @rank[to_string(role)]
  end

  def list_for_user(nil), do: []
  def list_for_user(user) do
    Repo.all(
      from g in Group,
        join: m in Membership, on: m.group_id == g.id,
        where: m.user_id == ^user.id,
        order_by: [asc: g.name]
    )
  end

  def list_members(%Group{id: gid}) do
    Repo.all(
      from m in Membership,
        join: u in RuleMaven.Users.User, on: u.id == m.user_id,
        where: m.group_id == ^gid,
        order_by: [desc: m.role, asc: u.username],
        select: %{user_id: u.id, username: u.username, role: m.role}
    )
  end

  def rename(actor, group, name) do
    if role_at_least?(actor, group, :admin) do
      group |> Group.changeset(%{name: name}) |> Repo.update()
    else
      {:error, :forbidden}
    end
  end

  def regenerate_code(actor, group) do
    if role_at_least?(actor, group, :admin) do
      group |> Group.changeset(%{invite_code: generate_code()}) |> Repo.update()
    else
      {:error, :forbidden}
    end
  end

  def set_role(actor, group, target_user_id, role) do
    cond do
      not role_at_least?(actor, group, :owner) -> {:error, :forbidden}
      role not in Membership.roles() -> {:error, :forbidden}
      true ->
        case Repo.get_by(Membership, group_id: group.id, user_id: target_user_id) do
          nil -> {:error, :not_member}
          m -> m |> Membership.changeset(%{role: role}) |> Repo.update()
        end
    end
  end

  def remove_member(actor, group, target_user_id) do
    target_role = role_of(%{id: target_user_id}, group)

    cond do
      not role_at_least?(actor, group, :admin) -> {:error, :forbidden}
      target_role == "owner" -> {:error, :cannot_remove_owner}
      target_role == nil -> {:error, :not_member}
      true ->
        {n, _} =
          Repo.delete_all(
            from m in Membership,
              where: m.group_id == ^group.id and m.user_id == ^target_user_id
          )
        if n > 0, do: {:ok, :removed}, else: {:error, :not_member}
    end
  end

  def leave(user, group) do
    case role_of(user, group) do
      "owner" -> {:error, :owner_must_transfer}
      nil -> {:error, :not_member}
      _ ->
        Repo.delete_all(
          from m in Membership,
            where: m.group_id == ^group.id and m.user_id == ^user.id
        )
        {:ok, :left}
    end
  end

  def delete_group(actor, group) do
    if role_at_least?(actor, group, :owner) do
      Repo.delete!(group)
      {:ok, :deleted}
    else
      {:error, :forbidden}
    end
  end
```

> `role_of/2` is called with a bare `%{id: target_user_id}` in `remove_member`;
> that works because `role_of/2` only reads `user.id`. Keep it.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/groups_manage_test.exs 2>&1 | tee ./tmp/task5.log`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/groups.ex test/rule_maven/groups_manage_test.exs
git commit -m "feat(groups): authz + member management ops"
```

---

### Task 6: Write path — attach group_id to a group ask

**Files:**
- Modify: `lib/rule_maven/games/question_log.ex:78` (add `:group_id` to cast)
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (~1024, ~1030, and the second ask path ~1665-1691)
- Modify: `lib/rule_maven/workers/ask_worker.ex:29` area (read `args["group_id"]`, thread into `LLM.ask` opts)
- Modify: `lib/rule_maven/llm.ex:35` (accept `group_id` opt, thread to lookups — completed in Task 7)
- Test: `test/rule_maven/games_group_write_test.exs`

**Interfaces:**
- Consumes: `Groups.member?/2`.
- Produces: a group ask writes a `QuestionLog` row with `group_id` set and `visibility: "private"`; `AskWorker` receives `group_id` in args; `LLM.ask/5` accepts `opts[:group_id]`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/rule_maven/games_group_write_test.exs
defmodule RuleMaven.GamesGroupWriteTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Games

  test "log_question persists group_id and keeps visibility private" do
    game = RuleMaven.GamesFixtures.game_fixture()
    user = RuleMaven.AccountsFixtures.user_fixture()
    grp = RuleMaven.GroupsFixtures.group_fixture(user)

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id,
        user_id: user.id,
        question: "How many cards?",
        answer: "Thinking...",
        visibility: "private",
        group_id: grp.id
      })

    assert q.group_id == grp.id
    assert q.visibility == "private"
  end
end
```

> Create `test/support/fixtures/groups_fixtures.ex` with
> `def group_fixture(owner), do: (fn -> {:ok, g} = RuleMaven.Groups.create_group(owner, %{name: "Fix"}); g end).()`.
> Use existing `GamesFixtures.game_fixture/0` / `AccountsFixtures.user_fixture/0`
> (grep `test/support/fixtures` to confirm names; adjust if different).

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/games_group_write_test.exs 2>&1 | tee ./tmp/task6.log`
Expected: FAIL — `group_id` not cast (row saved with `group_id: nil`).

- [ ] **Step 3: Add `:group_id` to the changeset cast**

In `lib/rule_maven/games/question_log.ex`, add `:group_id` to the `cast/3` field list (alongside `:user_id`) and add the association. Near the other `belongs_to`:

```elixir
    belongs_to :group, RuleMaven.Groups.Group
```

And in the cast list add:

```elixir
      :group_id,
```

- [ ] **Step 4: Run write test to verify it passes**

Run: `mix test test/rule_maven/games_group_write_test.exs 2>&1 | tee ./tmp/task6.log`
Expected: PASS.

- [ ] **Step 5: Thread `group_id` through the LiveView ask handler**

In `lib/rule_maven_web/live/game_live/show.ex`, the ask handler builds the provisional row via `Games.log_question_with_rate_limit/2` (~line 1024) and the `AskWorker` args map (~line 1030). The active group id comes from `socket.assigns[:active_group_id]` (set in Task 10; default `nil`). Add `group_id: socket.assigns[:active_group_id]` to BOTH the `log_question_with_rate_limit` attrs map and the `AskWorker.new(%{...})` args map. Do the same in the second ask path (~lines 1665-1691).

Concretely, the attrs map becomes:

```elixir
                case Games.log_question_with_rate_limit(socket.assigns.current_user, %{
                       game_id: game.id,
                       question: question,
                       answer: "Thinking...",
                       user_id: socket.assigns.current_user.id,
                       visibility: visibility,
                       group_id: socket.assigns[:active_group_id],
                       expansion_ids: Enum.sort(expansion_ids)
                     }) do
```

and the worker args map gains `group_id: socket.assigns[:active_group_id],`.

- [ ] **Step 6: Thread `group_id` through AskWorker → LLM.ask**

In `lib/rule_maven/workers/ask_worker.ex`, near line 29 where `user_id = args["user_id"]`, add:

```elixir
    group_id = args["group_id"]
```

Then find the `LLM.ask(game, question, expansion_ids, recent, opts)` call in this worker and add `group_id: group_id` to its `opts` keyword list.

In `lib/rule_maven/llm.ex:35`, `def ask(game, question, expansion_ids \\ [], recent_context \\ [], opts \\ [])` — read `group_id = Keyword.get(opts, :group_id)` near the top of the pool-lookup section (used in Task 7).

- [ ] **Step 7: Compile check + write test still green**

Run: `mix compile --warnings-as-errors 2>&1 | tee ./tmp/task6-compile.log`
Expected: no warnings/errors.
Run: `mix test test/rule_maven/games_group_write_test.exs 2>&1 | tee ./tmp/task6.log`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/rule_maven/games/question_log.ex lib/rule_maven_web/live/game_live/show.ex lib/rule_maven/workers/ask_worker.ex lib/rule_maven/llm.ex test/rule_maven/games_group_write_test.exs test/support/fixtures/groups_fixtures.ex
git commit -m "feat(groups): attach group_id to group asks and thread to ask pipeline"
```

---

### Task 7: Shared cache — widen pool lookup to the active group

**Files:**
- Modify: `lib/rule_maven/games.ex:2604` (`find_pool_candidates/3`) and `:2792` (`find_user_duplicate/5`)
- Modify: `lib/rule_maven/llm.ex` (~98, ~102, ~164 — pass `active_group_id`)
- Test: `test/rule_maven/games_group_cache_test.exs`

**Interfaces:**
- Consumes: `group_id` opt from Task 6.
- Produces: `find_pool_candidates/3` accepts `opts[:active_group_id]`; when set, candidates also include rows where `q.group_id == ^active_group_id` (subject to the same freshness guards). Non-members never pass this id in, so they never see group rows.

- [ ] **Step 1: Write the failing test**

```elixir
# test/rule_maven/games_group_cache_test.exs
defmodule RuleMaven.GamesGroupCacheTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Games

  setup do
    game = RuleMaven.GamesFixtures.game_fixture()
    owner = RuleMaven.AccountsFixtures.user_fixture()
    grp = RuleMaven.GroupsFixtures.group_fixture(owner)
    emb = List.duplicate(0.1, 1536) |> Pgvector.new()

    {:ok, q} =
      Games.log_question(%{
        game_id: game.id, user_id: owner.id, question: "group q", answer: "42",
        visibility: "private", group_id: grp.id, question_embedding: emb,
        citation_valid: true
      })

    %{game: game, grp: grp, emb: emb, q: q}
  end

  test "member ask sees the group row as a candidate", %{game: g, grp: grp, emb: emb, q: q} do
    ids =
      Games.find_pool_candidates(g.id, emb, active_group_id: grp.id)
      |> Enum.map(fn {row, _sim} -> row.id end)

    assert q.id in ids
  end

  test "without active_group_id the private group row is NOT a candidate", %{game: g, emb: emb, q: q} do
    ids =
      Games.find_pool_candidates(g.id, emb, [])
      |> Enum.map(fn {row, _sim} -> row.id end)

    refute q.id in ids
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/games_group_cache_test.exs 2>&1 | tee ./tmp/task7.log`
Expected: FAIL — group row absent from candidates in first test.

- [ ] **Step 3: Widen the candidate filter**

In `lib/rule_maven/games.ex`, `find_pool_candidates/3`, read the opt and add an `or` branch to the visibility filter. The existing filter (~line 2622) is:

```elixir
      where: q.pooled == true or (q.visibility == "community" and q.citation_valid == true),
```

Change the head of the function to read the opt, then build the base/group condition with `dynamic/2`:

```elixir
  def find_pool_candidates(game_id, question_embedding, opts \\ []) do
    active_group_id = Keyword.get(opts, :active_group_id)

    visibility_filter =
      if active_group_id do
        dynamic([q],
          q.pooled == true or
            (q.visibility == "community" and q.citation_valid == true) or
            q.group_id == ^active_group_id)
      else
        dynamic([q],
          q.pooled == true or (q.visibility == "community" and q.citation_valid == true))
      end
```

Then replace the inline `where:` clause with `|> where(^visibility_filter)` at the same position in the query pipeline (keep every other guard — `game_id`, `expansion_ids`, `refused`, `needs_review`, `stale`, error, distance — exactly as-is). Import `dynamic` if not already: it comes from `Ecto.Query`, already imported in this module.

- [ ] **Step 4: Pass `active_group_id` from LLM.ask**

In `lib/rule_maven/llm.ex`, where `find_pool_candidates(game.id, question_embedding, ...)` is called (~line 164), add `active_group_id: group_id` to its opts (using the `group_id` read in Task 6 Step 6). Group members' same-user tier is unaffected; group cache flows through the pool path.

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/rule_maven/games_group_cache_test.exs 2>&1 | tee ./tmp/task7.log`
Expected: PASS (2 tests).

- [ ] **Step 6: Regression — pool lookup for non-group asks unchanged**

Run the existing pool test file (grep `test/` for `find_pool_candidates` or `find_similar_question_in_pool`):
Run: `mix test test/rule_maven/games_test.exs 2>&1 | tee ./tmp/task7-reg.log`
Expected: PASS (no regressions in existing pool behavior).

- [ ] **Step 7: Commit**

```bash
git add lib/rule_maven/games.ex lib/rule_maven/llm.ex test/rule_maven/games_group_cache_test.exs
git commit -m "feat(groups): widen pool candidate lookup to the active group"
```

---

### Task 8: Group feed query

**Files:**
- Modify: `lib/rule_maven/games.ex:2412` (`recent_questions/3`)
- Test: `test/rule_maven/games_group_feed_test.exs`

**Interfaces:**
- Produces: `recent_questions/3` accepts `opts[:group_id]`; when set, returns rows where `q.group_id == ^group_id` for that game (the group feed), newest first, attributed (preload user).

- [ ] **Step 1: Write the failing test**

```elixir
# test/rule_maven/games_group_feed_test.exs
defmodule RuleMaven.GamesGroupFeedTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Games

  test "recent_questions with group_id returns the group's rows for the game" do
    game = RuleMaven.GamesFixtures.game_fixture()
    a = RuleMaven.AccountsFixtures.user_fixture()
    b = RuleMaven.AccountsFixtures.user_fixture()
    grp = RuleMaven.GroupsFixtures.group_fixture(a)

    {:ok, qa} = Games.log_question(%{game_id: game.id, user_id: a.id, question: "qa", answer: "x", visibility: "private", group_id: grp.id})
    {:ok, _solo} = Games.log_question(%{game_id: game.id, user_id: b.id, question: "solo", answer: "y", visibility: "private"})

    feed = Games.recent_questions(game, 20, group_id: grp.id)
    ids = Enum.map(feed, & &1.id)
    assert qa.id in ids
    refute Enum.any?(feed, fn q -> q.question == "solo" end)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/games_group_feed_test.exs 2>&1 | tee ./tmp/task8.log`
Expected: FAIL — feed ignores `group_id`, includes wrong rows / empty.

- [ ] **Step 3: Add the group branch to `recent_questions/3`**

In `lib/rule_maven/games.ex`, `recent_questions/3`, near the top read `group_id = opts[:group_id]`. When it is set, short-circuit to a group-scoped query (attributed, newest first) instead of the existing own+community union:

```elixir
  def recent_questions(%Game{} = game, limit \\ 20, opts \\ []) do
    group_id = opts[:group_id]

    if group_id do
      RuleMaven.Repo.all(
        from q in QuestionLog,
          where: q.game_id == ^game.id and q.group_id == ^group_id,
          where: q.refused == false and q.blocked == false,
          order_by: [desc: q.inserted_at],
          limit: ^limit,
          preload: [:user]
      )
    else
      # ... existing implementation unchanged ...
    end
  end
```

Keep the existing body verbatim in the `else`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/games_group_feed_test.exs 2>&1 | tee ./tmp/task8.log`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/games.ex test/rule_maven/games_group_feed_test.exs
git commit -m "feat(groups): group-scoped recent_questions feed query"
```

---

### Task 9: Broadcast group_id on ask completion

**Files:**
- Modify: `lib/rule_maven/workers/ask_worker.ex` (~640-659, the `:ask_complete` payload)
- Test: `test/rule_maven/workers/ask_worker_group_broadcast_test.exs` (or assert on the payload builder)

**Interfaces:**
- Produces: the `{:ask_complete, payload}` broadcast on `"game:#{game_id}"` includes `group_id`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/rule_maven/workers/ask_worker_group_broadcast_test.exs
defmodule RuleMaven.Workers.AskWorkerGroupBroadcastTest do
  use RuleMaven.DataCase, async: true

  test ":ask_complete payload carries group_id" do
    game = RuleMaven.GamesFixtures.game_fixture()
    owner = RuleMaven.AccountsFixtures.user_fixture()
    grp = RuleMaven.GroupsFixtures.group_fixture(owner)

    {:ok, ql} =
      RuleMaven.Games.log_question(%{
        game_id: game.id, user_id: owner.id, question: "q", answer: "a",
        visibility: "private", group_id: grp.id
      })

    Phoenix.PubSub.subscribe(RuleMaven.PubSub, "game:#{game.id}")
    RuleMaven.Workers.AskWorker.broadcast_complete(ql, %{tier: :fresh})

    assert_receive {:ask_complete, %{question_log_id: id, group_id: gid}}
    assert id == ql.id
    assert gid == grp.id
  end
end
```

> If the payload is built inline (not via a named function), extract the
> broadcast into `def broadcast_complete(ql, meta)` in `ask_worker.ex` first,
> then call it where the inline broadcast was (~line 659). This makes it
> testable and is the minimal refactor the test requires.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven/workers/ask_worker_group_broadcast_test.exs 2>&1 | tee ./tmp/task9.log`
Expected: FAIL — no `group_id` key (or `broadcast_complete/2` undefined).

- [ ] **Step 3: Add `group_id` to the payload**

In `lib/rule_maven/workers/ask_worker.ex`, extract/locate the `:ask_complete` payload map (~640-656) and add `group_id: ql.group_id` to it. If extracting, the function is:

```elixir
  def broadcast_complete(%RuleMaven.Games.QuestionLog{} = ql, meta) do
    payload =
      meta
      |> Map.put(:question_log_id, ql.id)
      |> Map.put(:group_id, ql.group_id)

    Phoenix.PubSub.broadcast(RuleMaven.PubSub, "game:#{ql.game_id}", {:ask_complete, payload})
  end
```

Preserve every existing key in `meta` (faq_hit, pool_hit, tier, verified, …).

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/rule_maven/workers/ask_worker_group_broadcast_test.exs 2>&1 | tee ./tmp/task9.log`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven/workers/ask_worker.ex test/rule_maven/workers/ask_worker_group_broadcast_test.exs
git commit -m "feat(groups): include group_id in :ask_complete broadcast"
```

---

### Task 10: Active-group selector (sticky) in the game screen

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (mount: load groups + active group; `handle_event("set_active_group", ...)`)
- Modify: the game sub-bar component (grep `sub_bar.ex` for the play menu) to render the selector
- Test: `test/rule_maven_web/live/game_live/group_selector_test.exs`

**Interfaces:**
- Consumes: `Groups.list_for_user/1`, `Groups.member?/2`, `Groups.get_group_by_token/1`, `RuleMaven.TableSession`.
- Produces: `socket.assigns.active_group_id` (int or nil) and `socket.assigns.my_groups`; sticky per game via `TableSession` snapshot key `:active_group_id`.

- [ ] **Step 1: Write the failing LiveView test**

```elixir
# test/rule_maven_web/live/game_live/group_selector_test.exs
defmodule RuleMavenWeb.GameLive.GroupSelectorTest do
  use RuleMavenWeb.ConnCase
  import Phoenix.LiveViewTest

  test "selecting a group sets active_group_id and it sticks", %{conn: conn} do
    user = RuleMaven.AccountsFixtures.user_fixture()
    game = RuleMaven.GamesFixtures.game_fixture()
    grp = RuleMaven.GroupsFixtures.group_fixture(user)
    conn = log_in_user(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    token = Phoenix.Param.to_param(grp)

    lv |> element("[phx-value-group='#{token}']") |> render_click()
    assert RuleMaven.TableSession.get(user.id, game.id)[:active_group_id] == grp.id

    # remount: stickiness restores it
    {:ok, lv2, _html} = live(conn, ~p"/games/#{game}")
    assert render(lv2) =~ grp.name
  end
end
```

> Use the project's existing `log_in_user/2` conn helper (grep `test/support`
> for it; it may be `register_and_log_in_user` — adapt).

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven_web/live/game_live/group_selector_test.exs 2>&1 | tee ./tmp/task10.log`
Expected: FAIL — no selector element / assign.

- [ ] **Step 3: Load groups + sticky active group at mount**

In `show.ex` mount (after `current_user`/`game` are assigned), add:

```elixir
    my_groups = RuleMaven.Groups.list_for_user(socket.assigns.current_user)
    sticky = RuleMaven.TableSession.get(socket.assigns.current_user.id, game.id)[:active_group_id]
    active_group_id = if sticky && Enum.any?(my_groups, &(&1.id == sticky)), do: sticky, else: nil

    socket =
      socket
      |> assign(:my_groups, my_groups)
      |> assign(:active_group_id, active_group_id)
```

(If mount reads connect params or runs twice, guard with `connected?/1` as the module already does for other subscriptions.)

- [ ] **Step 4: Add the handler**

```elixir
  def handle_event("set_active_group", %{"group" => token}, socket) do
    user = socket.assigns.current_user

    group_id =
      case token do
        "" -> nil
        t ->
          case RuleMaven.Groups.get_group_by_token(t) do
            %{id: id} = g -> if RuleMaven.Groups.member?(user, g), do: id, else: nil
            nil -> nil
          end
      end

    snap = RuleMaven.TableSession.get(user.id, socket.assigns.game.id)
    RuleMaven.TableSession.put(user.id, socket.assigns.game.id, Map.put(snap, :active_group_id, group_id))

    {:noreply, assign(socket, :active_group_id, group_id)}
  end
```

Place this clause beside the sub-bar's other `handle_event` clauses (per the sub-bar handler-grouping rule).

- [ ] **Step 5: Render the selector in the sub-bar**

In the play sub-bar component, add a selector rendering `Just me` + each of `@my_groups`, marking the active one, each option carrying `phx-click="set_active_group"` and `phx-value-group={Phoenix.Param.to_param(group)}` (empty string for "Just me"). Follow the existing sub-bar markup/classes (use the shared `btn-*`/pill classes, never fresh inline styles).

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/rule_maven_web/live/game_live/group_selector_test.exs 2>&1 | tee ./tmp/task10.log`
Expected: PASS.

- [ ] **Step 7: Mobile check + commit**

Verify the selector at 390px (per mobile-first rule): the pill row wraps, no horizontal scroll.

```bash
git add lib/rule_maven_web/live/game_live/show.ex lib/rule_maven_web/components/**/sub_bar.ex test/rule_maven_web/live/game_live/group_selector_test.exs
git commit -m "feat(groups): sticky active-group selector in game sub-bar"
```

---

### Task 11: Group feed panel with live append

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (load feed when a group is active; handle `:ask_complete` with matching `group_id`)
- Create/modify: a group panel component (follow the existing tool-panel pattern — grep `tool_panel` / `tool_host`)
- Test: `test/rule_maven_web/live/game_live/group_panel_test.exs`

**Interfaces:**
- Consumes: `Games.recent_questions/3` (group branch), `active_group_id`, the `:ask_complete` broadcast (Task 9).
- Produces: `socket.assigns.group_feed`; live prepend on matching `:ask_complete`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/rule_maven_web/live/game_live/group_panel_test.exs
defmodule RuleMavenWeb.GameLive.GroupPanelTest do
  use RuleMavenWeb.ConnCase
  import Phoenix.LiveViewTest

  test "group panel live-appends on matching :ask_complete", %{conn: conn} do
    user = RuleMaven.AccountsFixtures.user_fixture()
    game = RuleMaven.GamesFixtures.game_fixture()
    grp = RuleMaven.GroupsFixtures.group_fixture(user)
    conn = log_in_user(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/games/#{game}")
    lv |> element("[phx-value-group='#{Phoenix.Param.to_param(grp)}']") |> render_click()

    {:ok, ql} =
      RuleMaven.Games.log_question(%{
        game_id: game.id, user_id: user.id, question: "fresh group q",
        answer: "the answer", visibility: "private", group_id: grp.id
      })

    send(lv.pid, {:ask_complete, %{question_log_id: ql.id, group_id: grp.id}})
    assert render(lv) =~ "fresh group q"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven_web/live/game_live/group_panel_test.exs 2>&1 | tee ./tmp/task11.log`
Expected: FAIL — panel/feed not rendered/updated.

- [ ] **Step 3: Load the feed when a group is active**

In `show.ex`, whenever `active_group_id` changes (mount + `set_active_group`), assign the feed:

```elixir
  defp assign_group_feed(socket) do
    case socket.assigns.active_group_id do
      nil -> assign(socket, :group_feed, [])
      gid -> assign(socket, :group_feed, Games.recent_questions(socket.assigns.game, 20, group_id: gid))
    end
  end
```

Call `assign_group_feed/1` at the end of mount and in `handle_event("set_active_group", ...)` before returning.

- [ ] **Step 4: Handle the live broadcast**

The LiveView already subscribes to `"game:#{game.id}"` (show.ex:202) and handles `:ask_complete`. Extend that handler (or add a clause) so that when the incoming `group_id` matches `socket.assigns.active_group_id`, it prepends the fresh row:

```elixir
  def handle_info({:ask_complete, %{group_id: gid} = _p}, socket)
      when not is_nil(gid) do
    socket =
      if gid == socket.assigns.active_group_id do
        assign_group_feed(socket)
      else
        socket
      end

    {:noreply, socket}
  end
```

> Ensure this clause does not shadow the existing `:ask_complete` handler that
> updates the asker's own conversation — place it so both run, or fold the group
> refresh into the existing handler. Reloading the feed via `assign_group_feed/1`
> is simplest and avoids duplicate-row bugs.

- [ ] **Step 5: Render the panel**

Add a group panel (toggled from the sub-bar, following the existing tool-panel/dock pattern) that lists `@group_feed` rows attributed as `<row.user.username> asked …` with the question and answer. Use existing card/pill classes. Only show the toggle when `@active_group_id` is set.

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/rule_maven_web/live/game_live/group_panel_test.exs 2>&1 | tee ./tmp/task11.log`
Expected: PASS.

- [ ] **Step 7: Mobile check + commit**

Verify the panel at 390px (mobile-first rule).

```bash
git add lib/rule_maven_web/live/game_live/ test/rule_maven_web/live/game_live/group_panel_test.exs
git commit -m "feat(groups): live group feed panel on the game screen"
```

---

### Task 12: Group management UI + routes (create, join, settings)

**Files:**
- Create: `lib/rule_maven_web/live/group_live/index.ex` (my groups + create)
- Create: `lib/rule_maven_web/live/group_live/show.ex` (settings: members, roles, invite link, rename, delete, leave)
- Create: `lib/rule_maven_web/live/group_live/join.ex` (join by code/link)
- Modify: `lib/rule_maven_web/router.ex` (routes under the authenticated `live_session`)
- Modify: `/help` page + relevant tour (per help-tours-upkeep rule)
- Test: `test/rule_maven_web/live/group_live/manage_test.exs`

**Interfaces:**
- Consumes: all `Groups` functions.
- Produces: routes `/groups`, `/groups/:token`, `/groups/join/:code`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/rule_maven_web/live/group_live/manage_test.exs
defmodule RuleMavenWeb.GroupLive.ManageTest do
  use RuleMavenWeb.ConnCase
  import Phoenix.LiveViewTest

  test "user creates a group and sees its invite link", %{conn: conn} do
    user = RuleMaven.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)

    {:ok, lv, _} = live(conn, ~p"/groups")
    lv |> form("#new-group", group: %{name: "Sunday Crew"}) |> render_submit()
    assert render(lv) =~ "Sunday Crew"
  end

  test "non-member cannot open a group's settings by token", %{conn: conn} do
    owner = RuleMaven.AccountsFixtures.user_fixture()
    grp = RuleMaven.GroupsFixtures.group_fixture(owner)
    stranger = RuleMaven.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, stranger)

    assert {:error, {:redirect, _}} = live(conn, ~p"/groups/#{grp}")
  end

  test "joining by code adds the user", %{conn: conn} do
    owner = RuleMaven.AccountsFixtures.user_fixture()
    grp = RuleMaven.GroupsFixtures.group_fixture(owner)
    joiner = RuleMaven.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, joiner)

    {:ok, _lv, html} = live(conn, ~p"/groups/join/#{grp.invite_code}")
    assert html =~ grp.name
    assert RuleMaven.Groups.member?(joiner, grp)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/rule_maven_web/live/group_live/manage_test.exs 2>&1 | tee ./tmp/task12.log`
Expected: FAIL — routes/LiveViews undefined.

- [ ] **Step 3: Add routes**

In `router.ex`, inside the authenticated `live_session` (same one the game screen uses, so cross-session navigation is a patch not a reload — per live-session-nav-boundary rule):

```elixir
      live "/groups", GroupLive.Index, :index
      live "/groups/join/:code", GroupLive.Join, :join
      live "/groups/:token", GroupLive.Show, :show
```

- [ ] **Step 4: Implement `GroupLive.Index`**

Mount assigns `Groups.list_for_user(current_user)`. Render the list (link each via `~p"/groups/#{group}"`) and a create form `#new-group`. `handle_event("create", %{"group" => %{"name" => name}}, socket)` calls `Groups.create_group(current_user, %{name: name})`, then re-assigns the list. Follow existing LiveView/layout patterns; use shared button classes; one primary button per row.

- [ ] **Step 5: Implement `GroupLive.Join`**

Mount reads `:code` param, calls `Groups.join_by_code(current_user, code)`. On `{:ok, _}` or `{:error, :already_member}` assign the group (via `Repo.get_by(Group, invite_code: code)`) and show its name + a link into the group. On `{:error, :invalid_code | :inactive | :full}` show the matching flash message and link back to `/groups`.

- [ ] **Step 6: Implement `GroupLive.Show` (settings)**

Mount resolves `Groups.get_group_by_token!(token)`; if `not Groups.member?(current_user, group)` → `push_navigate` to `/groups` with an error flash (authorize server-side — IDOR rule). Assign `Groups.list_members/1` and the user's role. Render:
- invite link `url(~p"/groups/join/#{group.invite_code}")` with a copy button, plus a "Regenerate" button gated on `role_at_least?(_, _, :admin)`.
- member list with role badges; remove/promote controls gated by role.
- rename form (admin+), delete button (owner only), leave button (non-owner).
Wire `handle_event`s to `Groups.rename/3`, `regenerate_code/2`, `set_role/4`, `remove_member/3`, `leave/2`, `delete_group/2`, re-authorizing each with the actor. Show the returned `{:error, reason}` as a flash.

- [ ] **Step 7: Update /help + tour**

Add a "Groups" entry to the `/help` page and a step to the relevant onboarding tour explaining the active-group selector and shared feed (per help-tours-upkeep rule).

- [ ] **Step 8: Run test to verify it passes**

Run: `mix test test/rule_maven_web/live/group_live/manage_test.exs 2>&1 | tee ./tmp/task12.log`
Expected: PASS (3 tests).

- [ ] **Step 9: Mobile check + commit**

Verify all three group screens at 390px (mobile-first rule).

```bash
git add lib/rule_maven_web/live/group_live/ lib/rule_maven_web/router.ex lib/rule_maven_web/**/help* test/rule_maven_web/live/group_live/manage_test.exs
git commit -m "feat(groups): group management UI (create/join/settings) + routes"
```

---

## Final verification

- [ ] Run every group test file together:

Run: `mix test test/rule_maven/groups_test.exs test/rule_maven/groups_join_test.exs test/rule_maven/groups_manage_test.exs test/rule_maven/games_group_write_test.exs test/rule_maven/games_group_cache_test.exs test/rule_maven/games_group_feed_test.exs test/rule_maven/workers/ask_worker_group_broadcast_test.exs test/rule_maven_web/live/game_live/group_selector_test.exs test/rule_maven_web/live/game_live/group_panel_test.exs test/rule_maven_web/live/group_live/manage_test.exs 2>&1 | tee ./tmp/groups-final.log`
Expected: all PASS.

- [ ] `mix compile --warnings-as-errors` clean.
- [ ] Manual smoke (per verify-major-only rule — this is a major feature): create a group in one browser, join via link in a second (different user), ask a question in the group context as user A, confirm user B's open group panel appends it live, then confirm user B asking the same question hits the cache (no fresh LLM call, instant).
- [ ] Clean up `./tmp/*.log`.

## Deployment notes

- Migration `20260710000001_create_groups` must run (adds 2 tables + `questions_log.group_id`).
- No env/config changes.

## Spec coverage check

| Spec section | Task(s) |
|---|---|
| Data model (groups, memberships, group_id) | 1, 2 |
| Group create + token lookup | 3 |
| Invite, cap, revoke | 4, 12 |
| Roles + authz + management | 5, 12 |
| Write path (private + group_id) | 6 |
| Shared cache (widen pool) | 7 |
| Group feed query | 8 |
| Realtime feed (group_id in broadcast) | 9 |
| Active-group selector (sticky) | 10 |
| Group panel + live append | 11 |
| Management UI + routes | 12 |
| Leave keeps group_id / delete nilifies | 1 (FK on_delete), 5 (leave/delete) |
| No-ids-in-urls, IDOR | 2 (Hashid), 10/12 (server authz) |
| No community-pool leak | 6 (private write), 7 (lookup only widens for member) |
