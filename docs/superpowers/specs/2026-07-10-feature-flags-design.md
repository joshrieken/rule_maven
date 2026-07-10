# Feature Flags — Design

**Date:** 2026-07-10
**Status:** Approved, ready for implementation planning

## Problem

Rule Maven has two hand-rolled kill switches (`asks_disabled`, `email_disabled`) living as
string keys in `RuleMaven.Settings`, a plain KV table. They are inverted (`"true"` means
*off*), uncached (every read is a `Repo.get`), and enforced by ad-hoc `and not
socket.assigns.is_admin` checks scattered across `show.ex`. There is no way to gate a
half-built feature, grant a beta user early access, or ramp a change to a fraction of
users.

We want a single flag system covering four needs:

1. **Ops kill switches** — turn a feature off without a deploy (LLM spend, provider outage).
2. **Pre-launch gating** — ship to master continuously; hide WIP from everyone but admins.
3. **Per-user beta access** — named users see a feature before it is general.
4. **Percentage rollout / A-B** — ramp to N% of users, deterministically bucketed.

## Decisions

- **Buy, don't build.** `fun_with_flags` v1.13 implements all four gates, with Ecto
  persistence, an ETS cache, and PubSub cache-busting. Building this on `Settings` means
  reimplementing it worse; realistically we would stall after boolean gating.
- **Off means the feature vanishes** — not "greyed out with a tooltip". Hidden in the UI
  *and* rejected server-side.
- **Scope this spec to the registry, the 11 tools, and the two existing kill switches.**
  The 33 Oban workers get their own spec. The percentage *gate* exists from day one, but
  nothing declares `:experiment` yet — we have no metric wired to a bucket, so ramping a
  tool to 37% of users would produce no signal we would act on.
- **Flags are governed by a static registry**, not scattered atoms. See below.

## Architecture

### Dependency and configuration

```elixir
{:fun_with_flags, "~> 1.13"}
```

```elixir
# config/config.exs
config :fun_with_flags, :persistence,
  adapter: FunWithFlags.Store.Persistent.Ecto,
  repo: RuleMaven.Repo

config :fun_with_flags, :cache_bust_notifications,
  enabled: true,
  adapter: FunWithFlags.Notifications.PhoenixPubSub,
  client: RuleMaven.PubSub
```

`RuleMaven.PubSub` already exists (`application.ex:11`, `config.exs:24`). The app is
currently single-node (no `libcluster`), so the notifier is presently a no-op safeguard —
it costs nothing and means a second node cannot serve a stale flag later.

The table is created by copying the library's provided migration
(`priv/ecto_repo/migrations/00000000000000_create_feature_flags_table.exs` in the
`fun_with_flags` repo) into `priv/repo/migrations/`. Default table name:
`fun_with_flags_toggles`.

```elixir
# config/test.exs — the ETS cache is global and would leak flag state across
# sandboxed tests, producing order-dependent failures.
config :fun_with_flags, :cache, enabled: false
```

### `RuleMaven.Flags.Registry`

A static descriptor list, deliberately the same shape as
`RuleMavenWeb.GameLive.ToolRegistry`:

```elixir
%{id: :tool_quiz, label: "Rules quiz", kind: :ops, default: true}
```

| Field     | Meaning |
|-----------|---------|
| `id`      | atom, the flag name passed to `FunWithFlags` |
| `label`   | human string for the admin UI |
| `kind`    | `:ops` \| `:release` \| `:experiment` |
| `default` | value written by the sync task when no row exists |

`kind` is the governance mechanism, and it is the reason ~50 flags is survivable:

- `:ops` — a kill switch. Permanent by design. The 11 tools, `:asks`, `:outbound_email`.
- `:release` — a pre-launch gate. **Deleted the week it reaches 100%.**
- `:experiment` — a percentage rollout. **Deleted when the experiment concludes.**

Every flag declares at birth whether it is meant to outlive the quarter. Without this,
flags rot: each one is a branch that must keep working in both states, and combinatorially
they cannot all be tested.

Registry functions: `all/0`, `fetch!/1` (raises on unknown id — typo protection),
`by_kind/1`, `ids/0`.

### `RuleMaven.Flags` — the facade

```elixir
Flags.enabled?(:tool_quiz, user)   # -> boolean
Flags.enable(:tool_quiz)
Flags.disable(:tool_quiz)
Flags.enable(:tool_quiz, for_actor: user)
Flags.enable(:new_ask, for_group: "admin")
Flags.enable(:new_ask, for_percentage_of: {:actors, 0.2})
```

`enabled?/2` calls `Registry.fetch!/1` first (a compile-time map lookup, free) so a typo'd
flag raises instead of silently reading `false`, then delegates to
`FunWithFlags.enabled?(id, for: user)`, which is served from ETS.

### Protocol implementations

```elixir
defimpl FunWithFlags.Actor, for: RuleMaven.Users.User do
  def id(%{id: id}), do: "user:#{id}"
end

defimpl FunWithFlags.Group, for: RuleMaven.Users.User do
  def in?(user, "admin"), do: RuleMaven.Users.can?(user, :admin)
  def in?(_, _), do: false
end
```

Capability, not role string — per the standing `authorization-capabilities` rule.
`User.can?(_, _)` already falls through to `false`, and `FunWithFlags.enabled?/2` has a
dedicated `[for: nil]` clause, so the anonymous path needs no special-casing. (Game routes
are all inside `live_session :app` and therefore authenticated, so every flag check on a
game screen has a stable actor id — percentage bucketing works without an anonymous story.)

### Admin bypass comes free

`fun_with_flags` gate precedence is **actor > group > percentage > boolean**, and a group
gate overrides a disabled boolean gate. So "off for everyone, visible to admins" is:

```elixir
Flags.disable(:new_thing)
Flags.enable(:new_thing, for_group: "admin")
```

No `and not @is_admin` in application code — which is exactly what `asks_disabled` does
today in three places (`show.ex:939`, `show.ex:1593`, `show.ex:3838`).

## Enforcement — four sites

`ToolRegistry` gains user-aware variants. The existing zero-arity functions stay, for
metadata lookup and for the tests that assert registry shape.

```elixir
ToolRegistry.tools(user)      # filtered
ToolRegistry.group(g, user)   # filtered
ToolRegistry.visible?(id, user)
```

| Site | Current | Becomes | Why |
|------|---------|---------|-----|
| `sub_bar.ex:213` | `ToolRegistry.group(:play)` | `group(:play, @current_user)` | tool vanishes from menu |
| `sub_bar.ex:214` | `ToolRegistry.group(:learn)` | `group(:learn, @current_user)` | tool vanishes from menu |
| `tool_host.ex:658` `update_tool_state/3` | `safe_tool_id(tool)` | + `visible?(id, user)` on `:expanded` | forged event rejected |
| `tool_host.ex:157` `hydrate/3` | `ToolRegistry.valid?(id)` | `visible?(id, user)` | stale TableSession snapshot |

Three things the first draft of this spec got wrong, corrected after reading the code:

1. **`SubBar` has no `current_user` attr** — it has `is_admin`. A new
   `attr :current_user, :map, default: nil` must be added and threaded from all five
   `SubBar.game_bar` call sites: `show.ex:2413`, `community.ex:403`, `prepare.ex:694`,
   `review.ex:84`, `form.ex:2569`. All five LiveViews already assign `current_user`.

2. **`tool_host.ex:157` is not the event guard.** It is inside `hydrate/3`, which restores
   tool windows from a `TableSession` snapshot. It still needs gating — otherwise a
   snapshot taken before the flag flipped re-opens a flagged-off tool as a live panel — but
   it is a *different* hole from the forged event. It already has `user` in scope.

3. **`safe_tool_id/1` is a `defp` with no user in scope.** The real chokepoint is
   `update_tool_state/3` (line 658), the single funnel behind `open_tool`, `expand_tool`,
   `minimize_tool`, and `close_tool`. It has `socket`, therefore `current_user`.

**Gate only `:expanded` transitions.** `close_tool` and `minimize_tool` must always be
allowed: if a flag flips off while a user has that panel open, they still need to be able
to dismiss it. Rejecting every transition would trap the panel on screen.

`tool_panel.ex` only reads `.label` and `.emoji` for already-open tools and needs no
change.

Flag ids for tools follow `:tool_<id>` — `:tool_turn`, `:tool_first_player`,
`:tool_checklist`, `:tool_scorepad`, `:tool_timer`, `:tool_expansions`, `:tool_teach`,
`:tool_quiz`, `:tool_mistakes`, `:tool_dyk`, `:tool_house_rules`. All `kind: :ops`,
`default: true`.

## Migrating the two existing kill switches

`asks_disabled` → flag `:asks`. `email_disabled` → flag `:outbound_email`. Both flip
polarity: **`enabled` now means the feature works.**

This is the most breakable step in the plan. Getting the polarity backwards either silently
disables asks in production, or — worse — silently *enables* them during the provider
outage the switch was flipped for. It gets its own task, and a test asserting **both**
directions of the data migration:

- `app_settings["asks_disabled"] == "true"` → `:asks` boolean gate **disabled**
- `app_settings["asks_disabled"]` absent or `"false"` → `:asks` boolean gate **enabled**

`asks_disabled_message` stays in `Settings`. It is a message, not a flag.

The three `show.ex` call sites lose their `and not socket.assigns.is_admin` clause, because
the admin group gate now supplies that. `Mailer.deliver_email/1` reads
`Flags.enabled?(:outbound_email)`.

## The default problem

`FunWithFlags.enabled?/2` returns `false` for a flag with no persisted row. Most tool flags
default *on*. **A deploy that runs migrations but never seeds the flags makes all 11 tools
vanish at once.**

Mitigation: `mix rule_maven.flags.sync`

- Upserts every registry flag at its declared `default`. Idempotent — never overwrites an
  existing row, only inserts missing ones.
- Reports drift in both directions, using `FunWithFlags.all_flag_names/0`:
  - **orphans** — persisted flags no longer declared in the registry (delete them)
  - **unsynced** — registry flags with no row (the dangerous direction)
- `--check` mode exits non-zero on drift, for CI.

There is currently **no release pipeline** in this repo (no `release.ex`, no `fly.toml`, no
`Dockerfile`, no `release_command`). So this is a **manual deploy step**, and the spec says
so rather than pretending otherwise. It is added to the `ecto.setup` alias in `mix.exs` for
dev convenience.

**Documented failure mode: an unsynced flag is off.** Fail-closed. This is a real
operational hazard and is called out here so it is a known one.

## Admin UI

New `RuleMavenWeb.AdminLive.Flags` at `/admin/flags`, gated on `Users.can?(user, :admin)` —
the same gate as the rest of `/admin`, including the `asks_disabled` switch it replaces, so
this is no privilege change from the status quo.

Lists registry flags grouped by `kind`, with the human `label`. Per flag: boolean toggle,
per-user actor grants, group grants, percentage-of-actors slider.

We do **not** mount `fun_with_flags_ui`. It is a raw Plug with its own auth story, it shows
bare atom names, and it knows nothing of `kind` or `label`.

The two `admin_live/index.ex` toggle handlers (`asks_disabled`, `email_disabled`) are
rewritten to call `Flags.enable/disable`, keeping the dashboard banner working.

## Testing

- `config :fun_with_flags, :cache, enabled: false` in `config/test.exs`.
- `with_flag/3` test helper (set flag, run fun, restore).
- Registry parity: every `Registry.all/0` id syncs cleanly; sync is idempotent.
- `Flags.enabled?/2` raises on an unregistered id.
- **Precedence:** a boolean-disabled flag with an enabled `"admin"` group gate is `false`
  for a regular user and `true` for an admin.
- A flagged-off tool is absent from the Play/Learn menus.
- `open_tool` with a flagged-off tool id is rejected (the forged-event case).
- `close_tool` and `minimize_tool` on a flagged-off tool still work (the trapped-panel case).
- `hydrate/3` drops a flagged-off tool from a stale `TableSession` snapshot.
- Kill-switch migration, **both** polarities.

## Out of scope

- **The 33 Oban workers.** Own spec. Decided policy, recorded here so it is not relitigated —
  see "Worker cancellation and restore" below.
- **Any actual percentage rollout.** The gate ships; no flag declares `:experiment`.
- Cross-cutting features (personas, community answers, votes, tours, cheat sheets).

## Worker cancellation and restore (informs the follow-up worker spec)

Not built in this spec, but decided, and the reasoning verified against the vendored Oban
2.23 source so the worker spec does not have to rediscover it.

### `{:cancel, reason}`, not `:discard`

`executor.ex:256` and `:272` show that an explicit `:discard` return and a job that
**exhausted its retries** both land in the same `discarded` database state. A restore that
queried `state == "discarded"` would therefore resurrect genuinely-failed jobs alongside
flag-cancelled ones. There is no way to separate them after the fact.

`{:cancel, reason}` (`executor.ex:152`) instead maps to `state: :cancelled` with
`cancelled_at` set — a state Oban never assigns on failure. So:

```elixir
def perform(%Oban.Job{} = job) do
  if Flags.enabled?(:worker_quiz) do
    # ...real work...
  else
    {:cancel, "feature_flag:worker_quiz disabled"}
  end
end
```

Like `:discard`, this does **not** retry — the LLM spend a kill switch exists to stop is
stopped. Unlike `:discard`, it is unambiguously ours.

### Retention is already free

`config/config.exs:52` already sets `{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}`, and
`Oban.Engines.Basic.prune_jobs/3` prunes cancelled jobs on
`cancelled_at < now() - max_age`. **Cancelled jobs are retained for 7 days with no new
code.** We do not need a holding table, a tombstone, or a custom reaper.

### Do not gate at enqueue

Gating at insert time means no job row exists, so there is **nothing to restore**. Insert is
a cheap row write; the expensive thing is the LLM call inside `perform`. Cancelling at
`perform` gives both spend protection *and* restorability. Enqueue gating buys a saved row
insert and costs the entire recovery story. (This reverses the "gate at both enqueue and
perform" note in an earlier draft of this spec.)

### Restore

`Oban.retry_all_jobs/1` retries jobs "in any state other than `available` or `executing`",
so `cancelled` qualifies. The restore query is scoped three ways:

```elixir
from j in Oban.Job,
  where: j.state == "cancelled",
  where: j.worker in ^workers_for_flag(flag),
  where: j.cancelled_at >= ^disabled_at
```

`disabled_at` comes from `RuleMaven.Audit` — every flag flip is logged (`Audit.log/3`,
action `"flag.disable"` / `"flag.enable"`, `target_label` = the flag id), which gives both
the timestamp and the actor. The `worker` and `cancelled_at` bounds together ensure a
manual cancellation from Oban Web is never swept up.

### Automatic vs. manual

Auto-restoring on every re-enable would reintroduce exactly the thundering-herd spend spike
that made us reject `{:snooze, n}`: a flag left off for three days re-enables into a
three-day backlog firing at once.

So the restore is **time-bounded, not unconditional**:

- Flag was off for **less than `@auto_restore_window` (30 minutes)** → treat as an accidental
  flip. Auto-restore on re-enable. A 30-minute backlog is small by construction, which is
  what bounds the spend.
- Flag was off **longer** → no auto-restore. The admin flags UI shows
  *"142 jobs were cancelled while this was off. Restore?"* with a job count, and refuses a
  restore above `@max_restore_batch` without an explicit typed confirmation.

Both the flip and the restore are written to the audit log, and cancellations are reported
to the unified Jobs log (`job-log-convention`).

### Residual risk, stated plainly

A restored job re-runs against **today's** data, not the data it was enqueued against. If
the document it referenced was deleted or re-extracted while the flag was off, the job may
fail or write a stale result. Workers whose args reference a deleted row must tolerate that
— most already do, because Oban jobs can always outlive their subject. The worker spec must
audit this per worker rather than assume it.

## Deploy notes

1. `mix ecto.migrate` — creates `fun_with_flags_toggles`.
2. `mix rule_maven.flags.sync` — **required**, or every tool disappears.
3. Verify `/admin/flags` renders and the asks kill switch still toggles.
