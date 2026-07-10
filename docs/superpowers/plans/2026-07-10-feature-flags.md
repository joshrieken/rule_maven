# Feature Flags Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a feature-flag system covering ops kill switches, pre-launch gating, per-user beta access, and percentage rollout — built on `fun_with_flags` behind a thin `RuleMaven.Flags` facade and a static registry — and gate the 11 table tools through it, migrating the two existing hand-rolled kill switches in.

**Architecture:** Adopt `fun_with_flags` (Ecto persistence, ETS cache, Phoenix.PubSub cache-bust). A `RuleMaven.Flags.Registry` declares every flag (id, label, kind, default) in one static list, the same shape as `ToolRegistry`. `RuleMaven.Flags` wraps the library, validating ids against the registry. `ToolRegistry` gains user-aware variants; enforcement is at the four sites the spec identifies. The two `Settings` kill switches (`asks_disabled`, `email_disabled`) move into flags with inverted polarity.

**Tech Stack:** Elixir 1.15, Phoenix 1.8 LiveView, Ecto 3.13, Oban 2.23, `fun_with_flags` 1.13, ExUnit.

## Global Constraints

- **Authorization gates on capabilities, not role names:** `RuleMaven.Users.can?(user, :admin)`, never `user.role == "admin"`.
- **Admin UI gate is `can?(user, :admin)`** — the same gate as the rest of `/admin`. `UserLiveAuth.admin_view?/1` is a prefix match on `RuleMavenWeb.AdminLive.`, so any `AdminLive.*` module is auto-gated; no allowlist edit.
- **Every flag flip writes to the audit log** via `RuleMaven.Audit.log(actor, action, opts)`, action `"flag.enable"` / `"flag.disable"`, `target_label:` = the flag id string.
- **Run only tests relevant to the change**; tee output to `./tmp`. Do not run the full suite.
- **No new inline button styles** — reuse existing `btn-*` / `pill-*` classes.
- **Flag id convention:** tool flags are `:tool_<tool_id>` (e.g. `:tool_quiz`). All tool flags are `kind: :ops`, `default: true`.
- **Fail-closed:** a flag with no persisted row reads `false`. Tool defaults are `true`, so `mix rule_maven.flags.sync` MUST run after migrating or every tool vanishes.
- **`FunWithFlags` verified API (do not guess):** `enabled?(flag, for: actor)`, `enable(flag)`, `enable(flag, for_actor: a)`, `enable(flag, for_group: "admin")`, `enable(flag, for_percentage_of: {:actors, 0.2})`, `disable(flag)`, `clear(flag)`, `all_flag_names/0 -> {:ok, [atom]}`. Gate precedence: **actor > group > percentage > boolean**; a group gate overrides a disabled boolean gate.

---

## File Structure

- Create: `lib/rule_maven/flags.ex` — the facade.
- Create: `lib/rule_maven/flags/registry.ex` — static flag descriptors.
- Create: `lib/rule_maven/flags/protocols.ex` — `FunWithFlags.Actor` + `FunWithFlags.Group` impls for `User`.
- Create: `priv/repo/migrations/<ts>_create_feature_flags_table.exs` — copied from the library.
- Create: `priv/repo/migrations/<ts>_migrate_kill_switches_to_flags.exs` — data migration.
- Create: `lib/mix/tasks/rule_maven.flags.sync.ex` — sync/drift task.
- Create: `lib/rule_maven_web/live/admin_live/flags.ex` — admin UI.
- Modify: `mix.exs` (dep), `config/config.exs` (persistence + notifier), `config/test.exs` (cache off), `mix.exs` `ecto.setup` alias.
- Modify: `lib/rule_maven_web/live/game_live/tool_registry.ex` — user-aware variants.
- Modify: `lib/rule_maven_web/live/game_live/sub_bar.ex` — `current_user` attr + filtered groups.
- Modify: `lib/rule_maven_web/live/game_live/{show,community,prepare,review,form}.ex` — pass `current_user` to `game_bar`.
- Modify: `lib/rule_maven_web/live/game_live/tool_host.ex` — gate `update_tool_state/3` and `hydrate/3`.
- Modify: `lib/rule_maven_web/live/game_live/show.ex` — 3 `asks_disabled` sites.
- Modify: `lib/rule_maven/mailer.ex` — `email_disabled?` → flag.
- Modify: `lib/rule_maven_web/live/admin_live/index.ex` — toggle handlers call `Flags`.
- Modify: `lib/rule_maven_web/router.ex` — `/admin/flags` route.

---

## Task 1: Dependency, config, and the flags table

**Files:**
- Modify: `mix.exs` (deps + `ecto.setup` alias)
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Create: `priv/repo/migrations/<ts>_create_feature_flags_table.exs`
- Test: `test/rule_maven/flags_persistence_test.exs`

**Interfaces:**
- Produces: a working `FunWithFlags` runtime — `FunWithFlags.enable(:x)` / `enabled?(:x)` round-trip through Postgres and ETS. No app code yet.

- [ ] **Step 1: Add the dependency**

In `mix.exs`, in the `deps` list, add:

```elixir
{:fun_with_flags, "~> 1.13"},
```

- [ ] **Step 2: Fetch it**

Run: `mix deps.get`
Expected: `fun_with_flags` resolves at 1.13.x.

- [ ] **Step 3: Configure persistence and the notifier**

In `config/config.exs`, after the Oban block, add:

```elixir
# Feature flags — Ecto persistence, ETS cache, PubSub cache-busting.
config :fun_with_flags, :persistence,
  adapter: FunWithFlags.Store.Persistent.Ecto,
  repo: RuleMaven.Repo

config :fun_with_flags, :cache_bust_notifications,
  enabled: true,
  adapter: FunWithFlags.Notifications.PhoenixPubSub,
  client: RuleMaven.PubSub
```

- [ ] **Step 4: Disable the flag cache in tests**

In `config/test.exs`, add:

```elixir
# The ETS cache is global; disabling it stops flag state leaking across
# sandboxed tests and producing order-dependent failures.
config :fun_with_flags, :cache, enabled: false
```

- [ ] **Step 5: Create the flags table migration**

Create `priv/repo/migrations/<ts>_create_feature_flags_table.exs` (use a real timestamp via `mix ecto.gen.migration create_feature_flags_table` then replace the body) with the library's provided migration:

```elixir
defmodule RuleMaven.Repo.Migrations.CreateFeatureFlagsTable do
  use Ecto.Migration

  def up do
    create table(:fun_with_flags_toggles, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :flag_name, :string, null: false
      add :gate_type, :string, null: false
      add :target, :string, null: false
      add :enabled, :boolean, null: false
    end

    create index(
             :fun_with_flags_toggles,
             [:flag_name, :gate_type, :target],
             unique: true,
             name: "fwf_flag_name_gate_target_idx"
           )
  end

  def down do
    drop table(:fun_with_flags_toggles)
  end
end
```

- [ ] **Step 6: Migrate**

Run: `mix ecto.migrate`
Expected: `fun_with_flags_toggles` created.

- [ ] **Step 7: Write the persistence test**

Create `test/rule_maven/flags_persistence_test.exs`:

```elixir
defmodule RuleMaven.FlagsPersistenceTest do
  use RuleMaven.DataCase, async: false

  test "a boolean flag round-trips through the DB" do
    refute FunWithFlags.enabled?(:__test_persist_flag)
    {:ok, true} = FunWithFlags.enable(:__test_persist_flag)
    assert FunWithFlags.enabled?(:__test_persist_flag)
    {:ok, false} = FunWithFlags.disable(:__test_persist_flag)
    refute FunWithFlags.enabled?(:__test_persist_flag)
  end
end
```

Note: `async: false` — flag state is process-global even with the cache off, because it lives in Postgres outside the sandbox owner. Keep every flag test non-async and use uniquely-named flags.

- [ ] **Step 8: Run it**

Run: `mix test test/rule_maven/flags_persistence_test.exs 2>&1 | tee tmp/flags_persist.log`
Expected: PASS.

- [ ] **Step 9: Add sync to the ecto.setup alias (dev convenience)**

In `mix.exs`, change the `ecto.setup` alias from:

```elixir
"ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
```

to:

```elixir
"ecto.setup": ["ecto.create", "ecto.migrate", "rule_maven.flags.sync", "run priv/repo/seeds.exs"],
```

(The task defining `rule_maven.flags.sync` is Task 3; this line will error until then. That is fine — it is a dev alias, not a test dependency.)

- [ ] **Step 10: Commit**

```bash
git add mix.exs mix.lock config/config.exs config/test.exs priv/repo/migrations test/rule_maven/flags_persistence_test.exs
git commit -m "feat(flags): add fun_with_flags dependency, config, and table"
```

---

## Task 2: Registry, facade, and protocol implementations

**Files:**
- Create: `lib/rule_maven/flags/registry.ex`
- Create: `lib/rule_maven/flags.ex`
- Create: `lib/rule_maven/flags/protocols.ex`
- Test: `test/rule_maven/flags_test.exs`

**Interfaces:**
- Consumes: `FunWithFlags` (Task 1), `RuleMaven.Users.can?/2`.
- Produces:
  - `RuleMaven.Flags.Registry.all/0 :: [%{id: atom, label: String.t, kind: :ops | :release | :experiment, default: boolean}]`
  - `Registry.fetch!/1 :: map` (raises `KeyError` on unknown id)
  - `Registry.by_kind/1 :: [map]`, `Registry.ids/0 :: [atom]`
  - `RuleMaven.Flags.enabled?/2 :: boolean` (`enabled?(id, user \\ nil)`; raises on unregistered id)
  - `Flags.enable/2`, `Flags.disable/1`, `Flags.enable_for_admins/1`
  - `FunWithFlags.Actor` and `FunWithFlags.Group` impls for `RuleMaven.Users.User`

- [ ] **Step 1: Write the registry**

Create `lib/rule_maven/flags/registry.ex`:

```elixir
defmodule RuleMaven.Flags.Registry do
  @moduledoc """
  Static descriptor list for every feature flag. Same shape and spirit as
  `RuleMavenWeb.GameLive.ToolRegistry`: presentation and governance metadata
  only — the live on/off state lives in `fun_with_flags`, not here.

  `kind` governs a flag's lifecycle:
    * `:ops`        — a kill switch. Permanent by design.
    * `:release`    — a pre-launch gate. Deleted the week it reaches 100%.
    * `:experiment` — a percentage rollout. Deleted when the experiment concludes.
  """

  @tools ~w(turn first_player checklist scorepad timer expansions teach quiz mistakes dyk house_rules)a

  @tool_labels %{
    turn: "Turn Wizard",
    first_player: "Who goes first",
    checklist: "Setup checklist",
    scorepad: "Score pad",
    timer: "Turn timer",
    expansions: "Expansions",
    teach: "Teach it in 60s",
    quiz: "Rules quiz",
    mistakes: "Rules tables get wrong",
    dyk: "Did you know",
    house_rules: "House rules"
  }

  @tool_flags for t <- @tools,
                  do: %{id: :"tool_#{t}", label: @tool_labels[t], kind: :ops, default: true}

  @kill_switches [
    %{id: :asks, label: "Question answering (LLM asks)", kind: :ops, default: true},
    %{id: :outbound_email, label: "Outbound email", kind: :ops, default: true}
  ]

  @flags @tool_flags ++ @kill_switches

  @doc "All flag descriptors."
  def all, do: @flags

  @doc "All flag ids."
  def ids, do: Enum.map(@flags, & &1.id)

  @doc "Descriptors with the given kind."
  def by_kind(kind), do: Enum.filter(@flags, &(&1.kind == kind))

  @doc "Descriptor for an id. Raises `KeyError` if the id is not registered."
  def fetch!(id) do
    Enum.find(@flags, &(&1.id == id)) ||
      raise KeyError, "unregistered feature flag: #{inspect(id)}"
  end
end
```

- [ ] **Step 2: Write the facade**

Create `lib/rule_maven/flags.ex`:

```elixir
defmodule RuleMaven.Flags do
  @moduledoc """
  Thin facade over `fun_with_flags`. Every call validates the flag id against
  `RuleMaven.Flags.Registry`, so a typo raises instead of silently reading the
  library's "no row means false" default.

  Admin bypass is a group gate, not application code: `enable_for_admins/1`
  plus a disabled boolean means "off for everyone, on for admins", because
  `fun_with_flags` gate precedence puts group above boolean.
  """

  alias RuleMaven.Flags.Registry

  @doc "Whether `flag` is enabled, optionally for a specific user (nil = anonymous)."
  def enabled?(flag, user \\ nil) do
    Registry.fetch!(flag)
    FunWithFlags.enabled?(flag, for: user)
  end

  @doc "Enable a flag globally, or for an actor/group/percentage via opts."
  def enable(flag, opts \\ []) do
    Registry.fetch!(flag)
    FunWithFlags.enable(flag, opts)
  end

  @doc "Disable a flag globally, or for an actor/group/percentage via opts."
  def disable(flag, opts \\ []) do
    Registry.fetch!(flag)
    FunWithFlags.disable(flag, opts)
  end

  @doc "Grant a flag to admins as a group override, independent of its boolean gate."
  def enable_for_admins(flag) do
    Registry.fetch!(flag)
    FunWithFlags.enable(flag, for_group: "admin")
  end
end
```

- [ ] **Step 3: Write the protocol implementations**

Create `lib/rule_maven/flags/protocols.ex`:

```elixir
defimpl FunWithFlags.Actor, for: RuleMaven.Users.User do
  def id(%{id: id}), do: "user:#{id}"
end

defimpl FunWithFlags.Group, for: RuleMaven.Users.User do
  # Capability, not role string — see the authorization-capabilities rule.
  def in?(user, "admin"), do: RuleMaven.Users.can?(user, :admin)
  def in?(_user, _group), do: false
end
```

- [ ] **Step 4: Write the failing tests**

Create `test/rule_maven/flags_test.exs`:

```elixir
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
```

- [ ] **Step 5: Run to verify they fail**

Run: `mix test test/rule_maven/flags_test.exs 2>&1 | tee tmp/flags_test.log`
Expected: FAIL — modules not yet compiled / `create_user` role check. (If `"admin"` is not a valid role, check `RuleMaven.Users.User.assignable_roles/0` and use the real admin role string.)

- [ ] **Step 6: Verify the admin role string**

Run: `grep -n "role_capabilities\|assignable_roles\|@roles" lib/rule_maven/users/user.ex`
Expected: confirm the role string whose capability list includes `:admin`. Adjust the `user("admin")` calls in the test if the string differs.

- [ ] **Step 7: Run to verify pass**

Run: `mix test test/rule_maven/flags_test.exs 2>&1 | tee tmp/flags_test.log`
Expected: PASS (4 tests).

- [ ] **Step 8: Commit**

```bash
git add lib/rule_maven/flags.ex lib/rule_maven/flags/ test/rule_maven/flags_test.exs
git commit -m "feat(flags): registry, facade, and User actor/group protocols"
```

---

## Task 3: `mix rule_maven.flags.sync`

**Files:**
- Create: `lib/mix/tasks/rule_maven.flags.sync.ex`
- Test: `test/mix/tasks/flags_sync_test.exs`

**Interfaces:**
- Consumes: `Registry.all/0`, `FunWithFlags.all_flag_names/0`, `FunWithFlags.enable/disable`, `FunWithFlags.get_flag/1`.
- Produces: a mix task that upserts each registry flag at its default (only if it has no row), and reports drift. `--check` exits non-zero on drift.

- [ ] **Step 1: Write the task**

Create `lib/mix/tasks/rule_maven.flags.sync.ex`:

```elixir
defmodule Mix.Tasks.RuleMaven.Flags.Sync do
  @shortdoc "Seed missing feature flags at their registry defaults; report drift."
  @moduledoc """
  Ensures every flag in `RuleMaven.Flags.Registry` has a persisted row at its
  declared default. Idempotent: never overwrites an existing flag, only creates
  missing ones. Reports drift in both directions.

      mix rule_maven.flags.sync          # seed + report
      mix rule_maven.flags.sync --check  # report only, exit 1 on drift
  """
  use Mix.Task

  alias RuleMaven.Flags.Registry

  @requirements ["app.start"]

  @impl true
  def run(args) do
    check_only? = "--check" in args

    {:ok, persisted} = FunWithFlags.all_flag_names()
    persisted = MapSet.new(persisted)
    declared = MapSet.new(Registry.ids())

    unsynced = Registry.all() |> Enum.reject(&MapSet.member?(persisted, &1.id))
    orphans = MapSet.difference(persisted, declared) |> MapSet.to_list()

    Enum.each(unsynced, fn flag ->
      if check_only? do
        Mix.shell().info("UNSYNCED #{flag.id} (default: #{flag.default})")
      else
        if flag.default, do: FunWithFlags.enable(flag.id), else: FunWithFlags.disable(flag.id)
        Mix.shell().info("seeded #{flag.id} = #{flag.default}")
      end
    end)

    Enum.each(orphans, fn id -> Mix.shell().info("ORPHAN #{id} (not in registry)") end)

    if check_only? and (unsynced != [] or orphans != []) do
      Mix.raise("feature-flag drift detected")
    end
  end
end
```

- [ ] **Step 2: Write the test**

Create `test/mix/tasks/flags_sync_test.exs`:

```elixir
defmodule Mix.Tasks.RuleMaven.Flags.SyncTest do
  use RuleMaven.DataCase, async: false

  alias RuleMaven.Flags.Registry

  test "seeds missing flags at their defaults and is idempotent" do
    # nothing persisted yet
    {:ok, before} = FunWithFlags.all_flag_names()
    refute :tool_quiz in before

    Mix.Tasks.RuleMaven.Flags.Sync.run([])

    assert RuleMaven.Flags.enabled?(:tool_quiz, nil)

    # second run must not raise or change state
    Mix.Tasks.RuleMaven.Flags.Sync.run([])
    assert RuleMaven.Flags.enabled?(:tool_quiz, nil)

    {:ok, after_names} = FunWithFlags.all_flag_names()
    assert Enum.sort(Enum.uniq(after_names)) |> length() >= length(Registry.ids())
  after
    for id <- Registry.ids(), do: FunWithFlags.clear(id)
  end

  test "--check raises when a declared flag is unsynced" do
    assert_raise Mix.Error, fn ->
      Mix.Tasks.RuleMaven.Flags.Sync.run(["--check"])
    end
  end
end
```

- [ ] **Step 3: Run to verify fail, then implement passes it**

Run: `mix test test/mix/tasks/flags_sync_test.exs 2>&1 | tee tmp/flags_sync.log`
Expected: PASS once the task compiles. If `app.start` double-starts in test, remove `@requirements` (the test env already starts the app) — verify by running and reading the error.

- [ ] **Step 4: Commit**

```bash
git add lib/mix/tasks/rule_maven.flags.sync.ex test/mix/tasks/flags_sync_test.exs
git commit -m "feat(flags): mix rule_maven.flags.sync seed + drift task"
```

---

## Task 4: Gate the 11 tools

**Files:**
- Modify: `lib/rule_maven_web/live/game_live/tool_registry.ex`
- Modify: `lib/rule_maven_web/live/game_live/sub_bar.ex`
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (game_bar call ~2413)
- Modify: `lib/rule_maven_web/live/game_live/community.ex` (~403)
- Modify: `lib/rule_maven_web/live/game_live/prepare.ex` (~694)
- Modify: `lib/rule_maven_web/live/game_live/review.ex` (~84)
- Modify: `lib/rule_maven_web/live/game_live/form.ex` (~2569)
- Modify: `lib/rule_maven_web/live/game_live/tool_host.ex` (`hydrate/3` ~157, `update_tool_state/3` ~658)
- Test: `test/rule_maven_web/live/game_live/tool_flag_gate_test.exs`

**Interfaces:**
- Consumes: `RuleMaven.Flags.enabled?/2`, `RuleMaven.Flags.Registry`.
- Produces: `ToolRegistry.visible?/2`, `ToolRegistry.tools/1`, `ToolRegistry.group/2`. Existing zero-arity functions unchanged.

- [ ] **Step 1: Add user-aware variants to ToolRegistry**

In `lib/rule_maven_web/live/game_live/tool_registry.ex`, after `def valid?(id)`, add:

```elixir
  @doc """
  Whether a tool is both known and enabled for this user. A tool with no
  matching `:tool_<id>` flag in the registry is always visible (fail-open for
  tools we never chose to gate); a tool with a flag defers to `Flags`.
  """
  def visible?(id, user) do
    valid?(id) and flag_allows?(id, user)
  end

  @doc "Tools visible to this user."
  def tools(user), do: Enum.filter(@tools, &visible?(&1.id, user))

  @doc "Tools in a group visible to this user."
  def group(g, user), do: Enum.filter(group(g), &visible?(&1.id, user))

  defp flag_allows?(id, user) do
    flag = :"tool_#{id}"

    if flag in RuleMaven.Flags.Registry.ids() do
      RuleMaven.Flags.enabled?(flag, user)
    else
      true
    end
  end
```

- [ ] **Step 2: Add `current_user` to SubBar and filter the menus**

In `lib/rule_maven_web/live/game_live/sub_bar.ex`, add to **both** attr blocks (the `game_bar` component around line 25 and the inner one around line 65) after the `is_admin` attr:

```elixir
  attr :current_user, :map, default: nil
```

Then change lines ~213-214 from:

```heex
      <.group_menu emoji="🎲" label="Play" tools={ToolRegistry.group(:play)} />
      <.group_menu emoji="📚" label="Learn" tools={ToolRegistry.group(:learn)} />
```

to:

```heex
      <.group_menu emoji="🎲" label="Play" tools={ToolRegistry.group(:play, @current_user)} />
      <.group_menu emoji="📚" label="Learn" tools={ToolRegistry.group(:learn, @current_user)} />
```

(If `group_menu` is passed `@current_user` indirectly, confirm the assign name inside the component. The change is only the two `ToolRegistry.group/1` → `group/2` calls.)

- [ ] **Step 3: Pass current_user from all five game_bar call sites**

In each of `show.ex` (~2413), `community.ex` (~403), `prepare.ex` (~694), `review.ex` (~84), `form.ex` (~2569), add this attr to the `<SubBar.game_bar ...>` tag (next to `is_admin={...}`):

```heex
        current_user={@current_user}
```

All five LiveViews already assign `current_user`. Verify with:
`grep -n "current_user" lib/rule_maven_web/live/game_live/{show,community,prepare,review,form}.ex | head`

- [ ] **Step 4: Gate hydrate/3 in tool_host**

In `lib/rule_maven_web/live/game_live/tool_host.ex`, in `hydrate/3` (~line 152), change the comprehension filter from:

```elixir
          ToolRegistry.valid?(id),
```

to:

```elixir
          ToolRegistry.visible?(id, user),
```

(`user` is already the third arg of `hydrate/3`.)

- [ ] **Step 5: Gate update_tool_state/3 — only :expanded**

In `lib/rule_maven_web/live/game_live/tool_host.ex`, `update_tool_state/3` (~line 658). Change:

```elixir
  defp update_tool_state(socket, tool, state) do
    case safe_tool_id(tool) do
      nil ->
        socket

      id ->
```

to:

```elixir
  defp update_tool_state(socket, tool, state) do
    case safe_tool_id(tool) do
      nil ->
        socket

      id when state == :expanded ->
        # Opening/expanding a flagged-off tool is rejected. Closing and
        # minimizing must always pass, or a flag flipped while a panel is open
        # would trap it on screen.
        if ToolRegistry.visible?(id, socket.assigns.current_user) do
          apply_tool_state(socket, id, state)
        else
          socket
        end

      id ->
        apply_tool_state(socket, id, state)
    end
  end

  defp apply_tool_state(socket, id, state) do
```

...and the existing body (from `single? = socket.assigns.single_panel?` down through `assign_persist(...)`) becomes the body of `apply_tool_state/3`. Keep it verbatim; only the wrapper changed.

- [ ] **Step 6: Write the gate test**

Create `test/rule_maven_web/live/game_live/tool_flag_gate_test.exs`:

```elixir
defmodule RuleMavenWeb.GameLive.ToolFlagGateTest do
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import RuleMaven.GamesFixtures

  alias RuleMavenWeb.GameLive.ToolRegistry

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

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

  setup do
    {:ok, game: game_fixture(%{name: "Flag Game", bgg_id: System.unique_integer([:positive])})}
  end

  test "a flagged-off tool is hidden from the Learn menu", %{conn: conn, game: game} do
    {:ok, _} = RuleMaven.Flags.disable(:tool_quiz)
    u = user("user")

    {:ok, _view, html} = conn |> login(u) |> live(~p"/games/#{game.id}")

    refute html =~ "Rules quiz"
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "visible?/2 is true for an admin even when the boolean gate is off" do
    {:ok, _} = RuleMaven.Flags.disable(:tool_quiz)
    {:ok, _} = RuleMaven.Flags.enable_for_admins(:tool_quiz)

    refute ToolRegistry.visible?(:quiz, user("user"))
    assert ToolRegistry.visible?(:quiz, user("admin"))
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "opening a flagged-off tool via forged event is a no-op", %{conn: conn, game: game} do
    {:ok, _} = RuleMaven.Flags.disable(:tool_quiz)
    u = user("user")

    {:ok, view, _html} = conn |> login(u) |> live(~p"/games/#{game.id}")

    render_click(view, "open_tool", %{"tool" => "quiz"})
    refute render(view) =~ ~s(data-testid="tool-panel-quiz")
  after
    FunWithFlags.clear(:tool_quiz)
  end
end
```

Note: confirm the panel's real DOM marker (`grep -n "tool-panel\|data-testid" lib/rule_maven_web/live/game_live/tool_panel.ex`) and adjust the last assertion if it differs.

- [ ] **Step 7: Run the gate tests**

Run: `mix test test/rule_maven_web/live/game_live/tool_flag_gate_test.exs 2>&1 | tee tmp/tool_gate.log`
Expected: PASS (3 tests). Also run the existing registry test to confirm no regression:
`mix test test/rule_maven_web/live/game_live_tool_registry_test.exs 2>&1 | tee -a tmp/tool_gate.log`

- [ ] **Step 8: Seed flags for manual sanity (dev DB), then commit**

```bash
mix rule_maven.flags.sync
git add lib/rule_maven_web/live/game_live/ test/rule_maven_web/live/game_live/tool_flag_gate_test.exs
git commit -m "feat(flags): gate the 11 table tools, menus and events"
```

---

## Task 5: Migrate the two kill switches

**Files:**
- Create: `priv/repo/migrations/<ts>_migrate_kill_switches_to_flags.exs`
- Modify: `lib/rule_maven_web/live/game_live/show.ex` (lines ~939, ~1593, ~3838)
- Modify: `lib/rule_maven/mailer.ex` (~line 21)
- Modify: `lib/rule_maven_web/live/admin_live/index.ex` (mount ~13-14, `toggle_asks` ~27-42, `toggle_email` ~46-62)
- Test: `test/rule_maven/kill_switch_migration_test.exs`

**Interfaces:**
- Consumes: `RuleMaven.Flags`, `RuleMaven.Settings`.
- Produces: `:asks` and `:outbound_email` flags authoritative; polarity inverted (`enabled` = working). `Settings.asks_disabled_message/0` unchanged.

- [ ] **Step 1: Write the data migration (both polarities)**

Create `priv/repo/migrations/<ts>_migrate_kill_switches_to_flags.exs`:

```elixir
defmodule RuleMaven.Repo.Migrations.MigrateKillSwitchesToFlags do
  use Ecto.Migration
  import Ecto.Query

  # Data migration: copy the two hand-rolled kill switches from app_settings
  # into fun_with_flags, INVERTING polarity. Old "disabled"=true  => flag OFF.
  def up do
    flush()
    migrate("asks_disabled", :asks)
    migrate("email_disabled", :outbound_email)
  end

  def down do
    flush()
    # Non-destructive: leave the flags in place. app_settings rows were never removed.
    :ok
  end

  defp migrate(setting_key, flag) do
    disabled? =
      repo().one(
        from s in "app_settings", where: s.key == ^setting_key, select: s.value
      ) == "true"

    # enabled == working == NOT disabled
    if disabled?, do: FunWithFlags.disable(flag), else: FunWithFlags.enable(flag)
  end
end
```

Note: `flush()` then calling `FunWithFlags` requires the app started. Migrations run with the repo up but not necessarily the full app. If `FunWithFlags` is not available in the migration runtime, fall back to a raw insert into `fun_with_flags_toggles` (`gate_type: "boolean", target: "_fwf_boolean", enabled: <bool>`). Verify by running the migration once against dev; if it errors on `FunWithFlags`, switch to the raw insert form below:

```elixir
  defp put_boolean(repo, flag, enabled?) do
    repo.insert_all("fun_with_flags_toggles", [
      %{flag_name: to_string(flag), gate_type: "boolean", target: "_fwf_boolean", enabled: enabled?}
    ], on_conflict: {:replace, [:enabled]}, conflict_target: [:flag_name, :gate_type, :target])
  end
```

- [ ] **Step 2: Rewrite the three show.ex sites**

In `lib/rule_maven_web/live/game_live/show.ex`. Line ~311 (mount assign) change:

```elixir
        asks_disabled: RuleMaven.Settings.asks_disabled?(),
```

to:

```elixir
        asks_disabled: not RuleMaven.Flags.enabled?(:asks, socket.assigns.current_user),
```

Then the two `cond` guards (~939 and ~1593) change from:

```elixir
      RuleMaven.Settings.asks_disabled?() and not socket.assigns.is_admin ->
        {:noreply, put_flash(socket, :error, RuleMaven.Settings.asks_disabled_message())}
```

to:

```elixir
      not RuleMaven.Flags.enabled?(:asks, socket.assigns.current_user) ->
        {:noreply, put_flash(socket, :error, RuleMaven.Settings.asks_disabled_message())}
```

The admin bypass is now the flag's admin group gate (seeded in Step 6), so the `and not socket.assigns.is_admin` clause is deleted — do NOT keep it. The render banner at ~3838 uses the `@asks_disabled` assign already, so it needs no change beyond the mount assign above.

- [ ] **Step 3: Rewrite the mailer**

In `lib/rule_maven/mailer.ex`, change:

```elixir
      Settings.email_disabled?() ->
```

to:

```elixir
      not RuleMaven.Flags.enabled?(:outbound_email) ->
```

- [ ] **Step 4: Rewrite the admin index toggles**

In `lib/rule_maven_web/live/admin_live/index.ex`:

Mount assigns (~13-14) change:

```elixir
         asks_disabled: Settings.asks_disabled?(),
         email_disabled: Settings.email_disabled?(),
```

to:

```elixir
         asks_disabled: not RuleMaven.Flags.enabled?(:asks),
         email_disabled: not RuleMaven.Flags.enabled?(:outbound_email),
```

`toggle_asks` body change:

```elixir
      disable? = not socket.assigns.asks_disabled
      Settings.set_asks_disabled(disable?)

      Audit.log(
        socket.assigns.current_user,
        if(disable?, do: "asks.disable", else: "asks.enable")
      )
```

to:

```elixir
      disable? = not socket.assigns.asks_disabled
      if disable?, do: RuleMaven.Flags.disable(:asks), else: RuleMaven.Flags.enable(:asks)

      Audit.log(
        socket.assigns.current_user,
        if(disable?, do: "flag.disable", else: "flag.enable"),
        target_label: "asks"
      )
```

And the parallel change in `toggle_email` (flag `:outbound_email`, `target_label: "outbound_email"`).

- [ ] **Step 5: Write the migration test (both polarities)**

Create `test/rule_maven/kill_switch_migration_test.exs`:

```elixir
defmodule RuleMaven.KillSwitchMigrationTest do
  use RuleMaven.DataCase, async: false

  alias RuleMaven.{Flags, Settings}

  test "disabled=true in settings maps to the flag being OFF" do
    Settings.set_asks_disabled(true)
    migrate()
    refute Flags.enabled?(:asks, nil)
  after
    Settings.set_asks_disabled(false)
    FunWithFlags.clear(:asks)
  end

  test "absent/false setting maps to the flag being ON" do
    Settings.set_asks_disabled(false)
    migrate()
    assert Flags.enabled?(:asks, nil)
  after
    FunWithFlags.clear(:asks)
  end

  # Exercise the same logic the migration uses, without re-running the file.
  defp migrate do
    disabled? = Settings.get("asks_disabled") == "true"
    if disabled?, do: FunWithFlags.disable(:asks), else: FunWithFlags.enable(:asks)
  end
end
```

- [ ] **Step 6: Run migration on dev + seed the admin bypass, then run tests**

```bash
mix ecto.migrate
mix rule_maven.flags.sync
```

Then seed the admin bypass for asks so admins can still ask while paused (one-time, dev):

Run: `mix run -e 'RuleMaven.Flags.enable_for_admins(:asks)'`

Run tests:
`mix test test/rule_maven/kill_switch_migration_test.exs 2>&1 | tee tmp/killswitch.log`
Expected: PASS (2 tests).

Also run the ask-path LiveView tests that touch `asks_disabled` to confirm no regression:
`grep -rln "asks_disabled\|asks paused" test/ | xargs -r mix test 2>&1 | tee -a tmp/killswitch.log`

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations lib/rule_maven_web/live/game_live/show.ex lib/rule_maven/mailer.ex lib/rule_maven_web/live/admin_live/index.ex test/rule_maven/kill_switch_migration_test.exs
git commit -m "feat(flags): migrate asks/email kill switches into flags"
```

---

## Task 6: Admin flags UI

**Files:**
- Create: `lib/rule_maven_web/live/admin_live/flags.ex`
- Modify: `lib/rule_maven_web/router.ex` (~line 96, after the last AdminLive route)
- Test: `test/rule_maven_web/live/admin_live/flags_test.exs`

**Interfaces:**
- Consumes: `RuleMaven.Flags`, `RuleMaven.Flags.Registry`, `RuleMaven.Users.can?/2`, `RuleMaven.Audit`.
- Produces: `/admin/flags` LiveView listing flags grouped by kind with a boolean toggle each.

- [ ] **Step 1: Add the route**

In `lib/rule_maven_web/router.ex`, after `live "/admin/requests", AdminLive.Requests, :index`, add:

```elixir
      live "/admin/flags", AdminLive.Flags, :index
```

- [ ] **Step 2: Write the LiveView**

Create `lib/rule_maven_web/live/admin_live/flags.ex`:

```elixir
defmodule RuleMavenWeb.AdminLive.Flags do
  use RuleMavenWeb, :live_view

  alias RuleMaven.{Flags, Users, Audit}
  alias RuleMaven.Flags.Registry

  @impl true
  def mount(_params, _session, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      {:ok, assign(socket, page_title: "Feature Flags", flags: load_flags())}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    if Users.can?(socket.assigns.current_user, :admin) do
      flag = String.to_existing_atom(id)
      _ = Registry.fetch!(flag)
      on? = Flags.enabled?(flag, nil)

      if on?, do: Flags.disable(flag), else: Flags.enable(flag)

      Audit.log(
        socket.assigns.current_user,
        if(on?, do: "flag.disable", else: "flag.enable"),
        target_label: id
      )

      {:noreply,
       socket
       |> assign(flags: load_flags())
       |> put_flash(:info, "#{id} #{if on?, do: "disabled", else: "enabled"}.")}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
    end
  end

  defp load_flags do
    Registry.all()
    |> Enum.map(fn f -> Map.put(f, :on?, Flags.enabled?(f.id, nil)) end)
    |> Enum.group_by(& &1.kind)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container">
      <h1>Feature Flags</h1>
      <p class="text-secondary">
        Boolean gate shown. Off means the feature vanishes for everyone (admins may still
        see it via a group override set on the console).
      </p>

      <%= for {kind, flags} <- @flags do %>
        <h2>{kind |> Atom.to_string() |> String.capitalize()}</h2>
        <ul class="flag-list">
          <%= for f <- flags do %>
            <li style="display:flex;align-items:center;justify-content:space-between;gap:1rem;padding:0.5rem 0;border-bottom:1px solid var(--border)">
              <span>
                <strong>{f.label}</strong>
                <code class="text-muted">{f.id}</code>
              </span>
              <button
                type="button"
                class={["btn-sm", if(f.on?, do: "btn-primary", else: "btn-ghost")]}
                phx-click="toggle"
                phx-value-id={f.id}
              >
                {if f.on?, do: "On", else: "Off"}
              </button>
            </li>
          <% end %>
        </ul>
      <% end %>
    </div>
    """
  end
end
```

Note: confirm `btn-ghost` exists; the house-rules work found the real ghost class is `pill-link`. Run `grep -n "btn-ghost\|pill-link" priv/static/assets/css/app.css | head`. Use whichever exists; do not invent a class.

- [ ] **Step 3: Write the test**

Create `test/rule_maven_web/live/admin_live/flags_test.exs`:

```elixir
defmodule RuleMavenWeb.AdminLive.FlagsTest do
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

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

  test "renders flags grouped and toggles one", %{conn: conn} do
    {:ok, _} = RuleMaven.Flags.enable(:tool_quiz)
    admin = user("admin")

    {:ok, view, html} = conn |> login(admin) |> live(~p"/admin/flags")
    assert html =~ "Rules quiz"
    assert html =~ "tool_quiz"

    view |> element("button[phx-value-id=tool_quiz]") |> render_click()
    refute RuleMaven.Flags.enabled?(:tool_quiz, nil)
  after
    FunWithFlags.clear(:tool_quiz)
  end

  test "non-admin is redirected", %{conn: conn} do
    u = user("user")
    assert {:error, {:live_redirect, %{to: "/"}}} = conn |> login(u) |> live(~p"/admin/flags")
  end
end
```

Note: the non-admin redirect may surface as `{:redirect, ...}` or a `live_session` halt depending on `UserLiveAuth.on_mount(:app)`. Run the test; if the match fails, read the actual error tuple and adjust the assertion to match the real redirect shape (the admin gate halts before mount).

- [ ] **Step 4: Run the tests**

Run: `mix test test/rule_maven_web/live/admin_live/flags_test.exs 2>&1 | tee tmp/admin_flags.log`
Expected: PASS (2 tests).

- [ ] **Step 5: Add the admin nav link (if there is a nav)**

Run: `grep -rn "admin/usage\|admin/audit" lib/rule_maven_web/components/ lib/rule_maven_web/live/admin_live/*.ex | grep -i "href\|navigate" | head`
If an admin nav list exists, add a `~p"/admin/flags"` link beside the others, matching the existing markup. If none is found, skip this step.

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven_web/live/admin_live/flags.ex lib/rule_maven_web/router.ex test/rule_maven_web/live/admin_live/flags_test.exs
git commit -m "feat(flags): admin UI at /admin/flags"
```

---

## Self-Review Notes

**Spec coverage:**
- fun_with_flags + Ecto + ETS + PubSub → Task 1 ✓
- Registry with `kind` → Task 2 ✓
- Facade validating ids → Task 2 ✓
- Actor/Group protocols, capability-based admin group → Task 2 ✓
- Admin bypass via precedence → Tasks 2 (test), 4, 5 ✓
- Four enforcement sites (menus ×2, update_tool_state, hydrate) → Task 4 ✓
- `:expanded`-only gating (trapped-panel case) → Task 4 Step 5 ✓
- SubBar `current_user` attr threaded from 5 sites → Task 4 Steps 2-3 ✓
- Default problem + sync task + drift → Task 3 ✓
- Kill-switch migration both polarities → Task 5 ✓
- `asks_disabled_message` stays in Settings → Task 5 (untouched) ✓
- Admin UI, own LiveView not fun_with_flags_ui → Task 6 ✓
- Test cache disabled → Task 1 Step 4 ✓

**Deferred to the worker spec (out of scope here):** the 33 Oban workers, `{:cancel, reason}`, restore. Not in this plan by design.

**Known verify-in-place points flagged inline:** admin role string (Task 2 Step 6), migration-time `FunWithFlags` availability with raw-insert fallback (Task 5 Step 1), tool panel DOM marker (Task 4 Step 6), `btn-ghost` vs `pill-link` (Task 6 Step 2), non-admin redirect shape (Task 6 Step 3). Each has an explicit grep/run-and-read instruction rather than a guess.
