# Flag Targeting UI — Design (Spec A)

**Date:** 2026-07-10
**Status:** Approved, ready for implementation planning
**Depends on:** the feature-flag system (merged f31fb29): `RuleMaven.Flags`, `Flags.Registry`, `RuleMavenWeb.AdminLive.Flags` at `/admin/flags`.

## Problem

The flag system supports per-user (actor) grants and percentage-of-actors rollout at the
library level — `RuleMaven.Flags.enable/2` already passes `for_actor:` and
`for_percentage_of:` straight through to `fun_with_flags`. But the admin UI at
`/admin/flags` only exposes the boolean toggle. Granting a flag to one user, or ramping it
to 20% of users, currently requires a console (`mix run -e ...`). Make both clickable.

No new data model: `fun_with_flags` persists actor and percentage gates in its own
`fun_with_flags_toggles` table.

## Decisions

- Extend the existing `AdminLive.Flags` LiveView; do not add a page.
- Resolve usernames via `RuleMaven.Users.get_user_by_username/1` (verified to exist).
- Every gate change writes to the audit log, matching the existing boolean toggle
  (`Audit.log(user, "flag.enable"|"flag.disable", target_label: id)`).
- Gate precedence is unchanged and is the point: an actor grant overrides the boolean and
  the percentage; the percentage is only consulted when no actor/group gate matches.

## Per-flag controls (added to each row)

1. **Boolean toggle** — unchanged, already shipped.
2. **Grant to user.** A text input (username) + Grant / Revoke buttons.
   - Grant: `Flags.enable(flag, for_actor: user)`.
   - Revoke: `Flags.clear(flag, for_actor: user)` (clears the actor gate, reverting the
     user to whatever the boolean/percentage says).
   - Below the input, list the flag's current actor grants (username + Revoke each).
   - Unknown username → an inline flash `"No user named X."`, no state change.
3. **Percentage.** A range input **1–99** + Set / Clear.
   - `fun_with_flags` requires `0.0 < ratio < 1.0` (verified in `gate.ex`: both `0.0` and
     `1.0` raise `InvalidTargetError`). So the slider covers 1–99 only.
   - Set: `Flags.set_percentage(flag, n / 100)` for `n` in 1..99.
   - `n == 0` → clears the percentage gate (0% and no gate are equivalent). The input's min
     is 1; a "Clear" button is the explicit path to 0.
   - **100% is not a percentage gate** — it means "everyone", which is the boolean On
     toggle. The percentage control shows a hint to that effect rather than writing an
     invalid `1.0` gate.
   - Clear: `Flags.clear(flag, for_percentage: true)`.
   - Show the current percentage if a gate exists.

## Reading current gate state

`fun_with_flags` exposes `FunWithFlags.get_flag/1 -> %FunWithFlags.Flag{gates: [...]}`. A
`Flags.gates/1` facade function returns a normalized view the LiveView renders:

```elixir
%{
  boolean: true | false | nil,
  percentage: 0.2 | nil,            # {:actors, ratio}
  actors: ["user:1", "user:42"]     # enabled actor gate targets
}
```

The LiveView maps `"user:<id>"` back to usernames for display via `Users.get_user/1`.

## Facade additions

- `Flags.grant_actor(flag, %User{})` → `enable(flag, for_actor: user)`
- `Flags.revoke_actor(flag, %User{})` → `clear(flag, for_actor: user)`
- `Flags.set_percentage(flag, ratio)` → `enable(flag, for_percentage_of: {:actors, ratio})`
  for `0 < ratio < 1`; `ratio <= 0` → `clear(flag, for_percentage: true)`; `ratio >= 1`
  raises (callers must use the boolean toggle for 100%).
- `Flags.gates(flag)` → the normalized map above. Reads
  `FunWithFlags.get_flag(flag).gates`, a list of `%FunWithFlags.Gate{type, for, enabled}`
  (`type` ∈ `:boolean` | `:actor` | `:percentage_of_actors` | `:group`; actor `for` is the
  `"user:<id>"` string; percentage `for` is the ratio float).

Each validates the id against the registry first (the existing facade pattern) and is a
thin wrapper — the real gate logic stays in `fun_with_flags`.

## Authorization

Unchanged from the flags page: `Users.can?(user, :admin)` at mount and re-checked in every
event handler (an event on an open socket must not trust mount-time gating). The
`RuleMavenWeb.AdminLive.` prefix auto-gates the route.

## Testing

- `Flags.gates/1` reflects a boolean, an actor grant, and a percentage gate correctly.
- Granting an actor makes `enabled?(flag, that_user)` true even when the boolean is off,
  and false for a different user (precedence).
- Revoking an actor reverts that user to the boolean/percentage outcome.
- `set_percentage(flag, 0)` clears rather than writing a 0% gate.
- Unknown username in the grant event → flash, no gate written.
- Non-admin cannot fire the grant/percentage events (event-level re-check).
- All flag tests `async: false` with `FunWithFlags.clear/1` cleanup (the Ecto store does not
  roll back with the SQL sandbox).

## Out of scope

- Group-gate UI (only `"admin"` exists, provisioned by `flags.sync`).
- Anything experiment/variant-related — that is Spec B.
