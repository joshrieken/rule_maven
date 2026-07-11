# A/B Assignment Recording Implementation Plan (Spec B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record which A/B variant each user lands in, metric-agnostically, so any outcome metric can be joined to it later — a table, `Flags.variant/2`, and a counts readout on `/admin/flags`.

**Architecture:** A `experiment_assignments` table (one immutable row per user+experiment). `Flags.variant(flag, user)` returns `:treatment` iff the flag's percentage/actor gate is on for the user (reusing fun_with_flags' deterministic sticky bucketing), and records first exposure via `ON CONFLICT DO NOTHING`. `Flags.assignment_counts/1` powers a per-experiment readout. No outcome metric, lift, or multi-arm — those are a later spec.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, `fun_with_flags` 1.13, ExUnit.

## Global Constraints

- **`Flags.variant/2` requires a `kind: :experiment` flag** — raises otherwise (variant on an ops flag is a programming error). No registered experiment flags exist yet; tests add one to the registry OR use a test-only experiment flag (see Task 1 note).
- **Binary only:** `:treatment` iff `FunWithFlags.enabled?(flag, for: user)`, else `:control`. No separate bucketer — `variant` stays consistent with `enabled?` on the same flag.
- **First-exposure only:** one row per `(user_id, experiment)`, unique index, `Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :experiment])`.
- **A nil user is `:control` and is NOT recorded** (an experiment needs a stable actor).
- **Recording is inline** (a single indexed insert, realistic call site is a background worker before a multi-second LLM call). Do NOT wrap it in Oban/Task.
- **Table is immutable:** `timestamps(updated_at: false, type: :utc_datetime)`; unique index `(user_id, experiment)`; `on_delete: :delete_all` on the user FK (account deletion is a launch requirement).
- **Flag tests `async: false`** with `FunWithFlags.clear/1` cleanup (the fun_with_flags Ecto store does not roll back with the SQL sandbox). `config/test.exs` already disables the ETS cache.
- Schema module: `RuleMaven.Flags.ExperimentAssignment`, table `experiment_assignments`. Fields: `user_id`, `experiment` (string, the flag id), `variant` (string `"control"`/`"treatment"`), `inserted_at`.
- Registry descriptor shape is `%{id, label, kind, default, ...}`; `Registry.fetch!/1` raises on unknown ids; `kind ∈ :ops | :release | :experiment`.

---

## File Structure

- Create: `lib/rule_maven/flags/experiment_assignment.ex` — the schema.
- Create: `priv/repo/migrations/<ts>_create_experiment_assignments.exs` — the table.
- Modify: `lib/rule_maven/flags.ex` — add `variant/2` and `record_assignment/3` (private), `assignment_counts/1`.
- Modify: `lib/rule_maven/flags/registry.ex` — add one real experiment flag so `variant` has a registered target (see Task 1 for the exact entry).
- Modify: `lib/rule_maven_web/live/admin_live/flags.ex` — show counts on experiment rows.
- Test: `test/rule_maven/flags_variant_test.exs`, `test/rule_maven_web/live/admin_live/flags_experiment_readout_test.exs`.

---

## Task 1: Schema, migration, `variant/2`, and recording

**Files:**
- Create: `lib/rule_maven/flags/experiment_assignment.ex`
- Create: `priv/repo/migrations/<ts>_create_experiment_assignments.exs`
- Modify: `lib/rule_maven/flags.ex`
- Modify: `lib/rule_maven/flags/registry.ex`
- Test: `test/rule_maven/flags_variant_test.exs`

**Interfaces:**
- Consumes: `FunWithFlags.enabled?/2`, `Registry.fetch!/1`, `RuleMaven.Repo`, `RuleMaven.Users.User`.
- Produces:
  - `RuleMaven.Flags.ExperimentAssignment` schema with `changeset/2`.
  - `Flags.variant(flag, user) :: :treatment | :control` (records first exposure for a real user; raises on a non-`:experiment` flag; `:control` unrecorded for nil user).
  - `Flags.assignment_counts(flag) :: %{control: non_neg_integer, treatment: non_neg_integer}` (used by Task 2).

- [ ] **Step 1: Register a real experiment flag**

In `lib/rule_maven/flags/registry.ex`, the `@kill_switches` list (or wherever the non-tool
flags are assembled into `@flags`) gets one new experiment descriptor. Add a
`@experiments` list and fold it into `@flags`:

```elixir
  @experiments [
    %{id: :exp_ask_pipeline, label: "Experiment: new ask pipeline", kind: :experiment, default: false}
  ]

  @flags @tool_flags ++ @kill_switches ++ @experiments
```

`default: false` — an experiment is off (0% treatment) until an admin sets a percentage.
This gives `variant/2` a real registered target and makes the readout non-empty to build
against. (If `@flags` is currently `@tool_flags ++ @kill_switches`, change that line.)

- [ ] **Step 2: Write the schema**

Create `lib/rule_maven/flags/experiment_assignment.ex`:

```elixir
defmodule RuleMaven.Flags.ExperimentAssignment do
  @moduledoc """
  One immutable row per (user, experiment): the A/B variant a user was first
  assigned to, and when. Written by `RuleMaven.Flags.variant/2`. Metric-agnostic
  — outcome analysis joins this table by `user_id` + `inserted_at` later.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "experiment_assignments" do
    belongs_to :user, RuleMaven.Users.User
    field :experiment, :string
    field :variant, :string

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:user_id, :experiment, :variant])
    |> validate_required([:user_id, :experiment, :variant])
    |> validate_inclusion(:variant, ["control", "treatment"])
    |> unique_constraint([:user_id, :experiment], name: :experiment_assignments_user_id_experiment_index)
  end
end
```

- [ ] **Step 3: Write the migration**

Generate: `mix ecto.gen.migration create_experiment_assignments`, then replace the body:

```elixir
defmodule RuleMaven.Repo.Migrations.CreateExperimentAssignments do
  use Ecto.Migration

  def change do
    create table(:experiment_assignments) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :experiment, :string, null: false
      add :variant, :string, null: false

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create unique_index(:experiment_assignments, [:user_id, :experiment])
    create index(:experiment_assignments, [:experiment, :variant])
  end
end
```

- [ ] **Step 4: Run the migration**

Run: `mix ecto.migrate`
Expected: `experiment_assignments` created. The unique index is named
`experiment_assignments_user_id_experiment_index` (Ecto's default), matching the schema's
`unique_constraint` name.

- [ ] **Step 5: Write the failing tests**

Create `test/rule_maven/flags_variant_test.exs`:

```elixir
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
    RuleMaven.Repo.aggregate(from(a in ExperimentAssignment, where: a.experiment == ^to_string(exp)), :count)
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

  test "assignment_counts returns per-variant counts" do
    u1 = user()
    u2 = user()
    {:ok, _} = Flags.grant_actor(@exp, u1)
    Flags.variant(@exp, u1)  # treatment
    Flags.variant(@exp, u2)  # control

    counts = Flags.assignment_counts(@exp)
    assert counts.treatment == 1
    assert counts.control == 1
  after
    FunWithFlags.clear(@exp)
  end
end
```

- [ ] **Step 6: Run to verify they fail**

Run: `mix test test/rule_maven/flags_variant_test.exs 2>&1 | tee tmp/flags_variant.log`
Expected: FAIL — `variant/2` and `assignment_counts/1` undefined.

- [ ] **Step 7: Implement `variant/2`, recording, and `assignment_counts/1`**

In `lib/rule_maven/flags.ex`, add (after `gates/1`):

```elixir
  alias RuleMaven.Flags.ExperimentAssignment
  # (add `import Ecto.Query, only: [from: 2]` near the top of the module if not present)

  @doc """
  The experiment variant for `user`, recording first exposure. `:treatment` iff the
  flag's gate is on for the user, else `:control`. Requires a `kind: :experiment` flag.
  A nil user is `:control` and is not recorded.
  """
  def variant(flag, user \\ nil)

  def variant(flag, nil) do
    ensure_experiment!(flag)
    :control
  end

  def variant(flag, %RuleMaven.Users.User{} = user) do
    ensure_experiment!(flag)
    variant = if FunWithFlags.enabled?(flag, for: user), do: :treatment, else: :control
    record_assignment(user.id, flag, variant)
    variant
  end

  @doc "Assignment counts per variant. %{control: n, treatment: m}."
  def assignment_counts(flag) do
    Registry.fetch!(flag)

    rows =
      RuleMaven.Repo.all(
        from a in ExperimentAssignment,
          where: a.experiment == ^to_string(flag),
          group_by: a.variant,
          select: {a.variant, count(a.id)}
      )
      |> Map.new()

    %{control: Map.get(rows, "control", 0), treatment: Map.get(rows, "treatment", 0)}
  end

  defp ensure_experiment!(flag) do
    case Registry.fetch!(flag) do
      %{kind: :experiment} -> :ok
      _ -> raise ArgumentError, "variant/2 requires a :experiment flag, got #{inspect(flag)}"
    end
  end

  defp record_assignment(user_id, flag, variant) do
    %ExperimentAssignment{}
    |> ExperimentAssignment.changeset(%{
      user_id: user_id,
      experiment: to_string(flag),
      variant: to_string(variant)
    })
    |> RuleMaven.Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :experiment])
  end
```

Note: `Registry.fetch!/1` already raises `KeyError` on an unregistered id, so
`ensure_experiment!` raises `KeyError` there and `ArgumentError` for a registered-but-wrong-kind
flag. The test asserts `ArgumentError` for `:tool_quiz` (registered, kind `:ops`) — correct.

- [ ] **Step 8: Run to verify pass**

Run: `mix test test/rule_maven/flags_variant_test.exs 2>&1 | tee tmp/flags_variant.log`
Expected: PASS (7 tests). Also run the registry parity test to confirm the new flag didn't
break tool/flag parity (the experiment flag is not a `:tool_` flag, so parity holds):
`mix test test/rule_maven/flags_test.exs 2>&1 | tee -a tmp/flags_variant.log`

- [ ] **Step 9: Sync the new flag on dev + commit**

```bash
mix rule_maven.flags.sync   # seeds :exp_ask_pipeline at default false
git add lib/rule_maven/flags.ex lib/rule_maven/flags/experiment_assignment.ex lib/rule_maven/flags/registry.ex priv/repo/migrations test/rule_maven/flags_variant_test.exs
git commit -m "feat(flags): experiment_assignments table + Flags.variant/2 recording"
```

---

## Task 2: Assignment counts readout on /admin/flags

**Files:**
- Modify: `lib/rule_maven_web/live/admin_live/flags.ex`
- Test: `test/rule_maven_web/live/admin_live/flags_experiment_readout_test.exs`

**Interfaces:**
- Consumes: `Flags.assignment_counts/1`, the existing `load_flags/0`.
- Produces: the readout; no downstream consumers.

- [ ] **Step 1: Write the failing test**

Create `test/rule_maven_web/live/admin_live/flags_experiment_readout_test.exs`:

```elixir
defmodule RuleMavenWeb.AdminLive.FlagsExperimentReadoutTest do
  use RuleMavenWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @exp :exp_ask_pipeline

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

  test "experiment row shows control/treatment counts", %{conn: conn} do
    admin = user("admin")
    subject = user("user")
    {:ok, _} = RuleMaven.Flags.grant_actor(@exp, subject)
    RuleMaven.Flags.variant(@exp, subject)      # treatment
    RuleMaven.Flags.variant(@exp, user("user")) # control

    {:ok, _view, html} = conn |> login(admin) |> live(~p"/admin/flags")

    assert html =~ "control: 1"
    assert html =~ "treatment: 1"
  after
    FunWithFlags.clear(@exp)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/rule_maven_web/live/admin_live/flags_experiment_readout_test.exs 2>&1 | tee tmp/flags_readout.log`
Expected: FAIL — counts not rendered.

- [ ] **Step 3: Add counts to load_flags for experiment flags**

In `lib/rule_maven_web/live/admin_live/flags.ex`, in `load_flags/0`, add a `:counts` field
for experiment flags only (avoid a query per non-experiment flag):

```elixir
  defp load_flags do
    Registry.all()
    |> Enum.map(fn f ->
      f
      |> Map.put(:on?, Flags.enabled?(f.id, nil))
      |> Map.put(:gates, gate_view(f.id))
      |> Map.put(:counts, if(f.kind == :experiment, do: Flags.assignment_counts(f.id), else: nil))
    end)
    |> Enum.group_by(& &1.kind)
  end
```

- [ ] **Step 4: Render the counts on experiment rows**

In the render function, inside the per-flag `<li>` (after the targeting controls block, before
the closing `</li>`), add:

```heex
              <div :if={f.counts} style="margin-top:0.35rem;font-size:0.8rem" class="text-secondary">
                Assignments — control: {f.counts.control} · treatment: {f.counts.treatment}
              </div>
```

- [ ] **Step 5: Run to verify pass**

Run: `mix test test/rule_maven_web/live/admin_live/flags_experiment_readout_test.exs 2>&1 | tee tmp/flags_readout.log`
Expected: PASS. Also re-run the existing flags LiveView tests for no regression:
`mix test test/rule_maven_web/live/admin_live/flags_test.exs test/rule_maven_web/live/admin_live/flags_targeting_test.exs 2>&1 | tee -a tmp/flags_readout.log`

- [ ] **Step 6: Commit**

```bash
git add lib/rule_maven_web/live/admin_live/flags.ex test/rule_maven_web/live/admin_live/flags_experiment_readout_test.exs
git commit -m "feat(flags): assignment counts readout on experiment rows"
```

---

## Self-Review Notes

**Spec coverage:**
- `experiment_assignments` table, immutable, unique (user,experiment), on_delete delete_all → Task 1 Steps 2-3 ✓
- `Flags.variant/2` — binary, `:treatment` iff enabled?, first-exposure ON CONFLICT, requires :experiment, nil→:control unrecorded → Task 1 Step 7 ✓
- Inline recording (no Oban/Task) → Task 1 Step 7 (`record_assignment` is a direct Repo.insert) ✓
- `assignment_counts/1` → Task 1 Step 7 ✓
- Counts readout on /admin/flags experiment rows → Task 2 ✓
- Deterministic sticky bucketing reused (variant wraps enabled?) → Task 1 Step 7, tested by "consistent with enabled?" ✓
- async:false + clear cleanup → both test files ✓

**Out of scope (per spec), no task:** outcome metrics, lift, significance, multi-arm, per-exposure stream, conclude/promote flow, anonymous bucketing.

**Verify-in-place flagged inline:** `@flags` assembly line in registry.ex (Task 1 Step 1 — confirm the current RHS before editing); the exact `<li>` insertion point in the render (Task 2 Step 4 — the targeting-controls block was added by Spec A; insert after it).

**A/B determinism note:** the "consistent with enabled?" test uses an actor grant (deterministic) rather than a percentage gate, so it is not flaky. A percentage-bucketing determinism test would need many users to be meaningful and is not worth the flakiness surface here — the spec's determinism guarantee comes from fun_with_flags itself, which its own suite covers.
