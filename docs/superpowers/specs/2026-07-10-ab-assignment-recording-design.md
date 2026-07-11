# A/B Assignment Recording — Design (Spec B)

**Date:** 2026-07-10
**Status:** Approved, ready for implementation planning
**Depends on:** the feature-flag system (merged f31fb29): `RuleMaven.Flags`, `Flags.Registry`
(`kind: :experiment` already exists as a declared value), the percentage-of-actors gate.

## Problem

The percentage gate already assigns users to buckets deterministically and stickily — the
same user always lands in the same bucket, and ramping 20%→30% never re-rolls the first 20%.
That is real A/B *assignment*. What is missing is *recording*: nothing captures which
variant a user landed in, so an experiment can be shown but not measured.

This spec builds the metric-agnostic backbone: record each user's variant with a timestamp,
so any outcome metric can be joined to it later. It deliberately builds **no** outcome
metric, lift calculation, or significance test — those are a later spec, a SQL join away.

## Decisions (from brainstorming)

- **Recording is triggered by an explicit `Flags.variant(flag, user)` call** at the decision
  point, not auto-recorded on every `enabled?`. You record where an experiment actually
  branches; the call site documents the experiment.
- **First-exposure only, one row per (user, experiment).** Unique index, `ON CONFLICT DO
  NOTHING`. This is all an outcome-join needs: who was in which arm, from when.
- **Binary: control vs treatment.** Maps directly onto the percentage-of-actors gate
  (`enabled?` true = treatment). One flag = one experiment. No separate bucketer.

## Data model

New table `experiment_assignments`, schema `RuleMaven.Flags.ExperimentAssignment`:

| column       | type                | notes |
|--------------|---------------------|-------|
| `id`         | bigserial           | pk |
| `user_id`    | references(:users)  | not null, on_delete: delete_all |
| `experiment` | string              | the flag id, e.g. `"new_ask"` — not null |
| `variant`    | string              | `"control"` or `"treatment"` — not null |
| `inserted_at`| utc_datetime        | first-exposure time |

- No `updated_at` — a row is immutable once written.
- Unique index on `(user_id, experiment)` — the conflict target that enforces
  first-exposure-only.
- Index on `(experiment, variant)` — for the counts readout.
- `on_delete: delete_all`: when a user is deleted (account deletion is a launch
  requirement), their assignment rows go too. This is assignment metadata, not audit — it
  is acceptable to lose it with the user. (If a future outcome analysis needs to survive
  user deletion, that is that spec's problem, not this one's.)

## The one new function

```elixir
# RuleMaven.Flags

@doc """
Returns the experiment variant for this user and records first exposure.
`:treatment` iff the percentage/actor gate is on for the user, else `:control`.
Requires a `kind: :experiment` flag. A nil user is always `:control` and is not
recorded (an experiment needs a stable actor to bucket).
"""
def variant(flag, user)

def variant(flag, nil) do
  desc = Registry.fetch!(flag)
  ensure_experiment!(desc)
  :control
end

def variant(flag, %RuleMaven.Users.User{} = user) do
  desc = Registry.fetch!(flag)
  ensure_experiment!(desc)
  variant = if FunWithFlags.enabled?(flag, for: user), do: :treatment, else: :control
  record_assignment(user.id, flag, variant)
  variant
end
```

- `ensure_experiment!/1` raises unless `desc.kind == :experiment` — `variant` on an ops flag
  is a programming error, caught loudly.
- `variant` is a strict wrapper over `enabled?`, so it stays consistent with any
  `enabled?(flag, user)` check elsewhere on the same flag, and inherits fun_with_flags'
  deterministic sticky bucketing. No independent hashing.

## Recording — inline, not async

```elixir
defp record_assignment(user_id, flag, variant) do
  %ExperimentAssignment{}
  |> ExperimentAssignment.changeset(%{
    user_id: user_id, experiment: to_string(flag), variant: to_string(variant)
  })
  |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :experiment])
end
```

**Inline is deliberate and brushes the never-block-the-LiveView rule, so it is justified
here:** the insert is a single indexed write (~1ms), and the realistic call site is inside a
background Oban worker — e.g. an ask-pipeline experiment branches in `ask_worker`, not in
the LiveView, immediately before a multi-second LLM call. One 1ms insert there blocks
nothing that matters, and making it durable-async (an Oban job per ask) would cost far more
than the write it defers. Losing a first-exposure record on a crash is not catastrophic: the
user is still deterministically bucketed by fun_with_flags; only the timestamp row is missed,
and the next exposure writes it. If a future experiment must branch inside an interactive
LiveView path, that caller can wrap the `variant/2` call in `start_async`; the default is
inline.

## Visibility — the counts readout

```elixir
# RuleMaven.Flags
@doc "Assignment counts per variant for an experiment. %{control: n, treatment: m}."
def assignment_counts(flag)
```

A single grouped query over `experiment_assignments`. Rendered on the experiment flag's row
in `/admin/flags` (which groups by `kind`, so experiments already cluster under an
"Experiment" heading): `control: N · treatment: M`. That is the entire readout — counts per
arm, no metric, no lift. It exists so the framework is visible without hand-written SQL.

## Concluding an experiment (manual, documented — not built)

Set the percentage to 100 (ship to all) or 0 (kill), then delete the flag from
`Flags.Registry`. The `experiment_assignments` rows persist as the historical record of who
was exposed. No automated "promote winner" flow — YAGNI until there is a metric to declare a
winner by.

## Testing

- `variant/2` returns `:treatment` when the gate is on for the user, `:control` when off,
  consistent with `enabled?/2` on the same flag.
- First call records a row; a second call for the same (user, experiment) does not insert a
  duplicate (unique index + `ON CONFLICT DO NOTHING`).
- `variant/2` raises on a non-`:experiment` flag.
- `variant(flag, nil)` returns `:control` and records nothing.
- `assignment_counts/1` returns correct per-variant counts.
- A percentage gate at a known ratio buckets a fixed set of users deterministically (same
  users → same variants across repeated calls).
- All flag tests `async: false` with `FunWithFlags.clear/1` cleanup.

## Out of scope (explicitly)

- Any outcome metric (answer quality, cost, retention), lift, or significance — a later
  spec joins those to `experiment_assignments` by `user_id` + `inserted_at`.
- Multi-arm (A/B/C) experiments — binary only; multi-arm needs a separate bucketer.
- Per-exposure event stream — first-exposure only.
- An automated conclude/promote flow.
- Anonymous/session-based bucketing — a nil user is `:control`, unrecorded.
