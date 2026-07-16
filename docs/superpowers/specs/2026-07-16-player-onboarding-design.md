# Player Onboarding — Design

**Date:** 2026-07-16
**Status:** Approved, pre-implementation
**Approach:** Getting Started panel (derive-not-store), aha-then-reward sequence

## Problem

New players log in and see a list of Ready games (Catan, etc.) they can ask against.
The value pieces already exist — tours, per-game XP HUD + level-up confetti, StandingLive
(points/badges/streaks-of-contribution), personas, /help — but nothing stitches them into a
first-run experience that (1) delivers a fast "aha" and (2) plants a retention hook.

**Goal:** a two-part sequence.

1. **Aha** — pick a Ready game → ask → get a grounded answer → feel it was worth it.
2. **Reward teaser** — immediately show the progression ladder the answer just stepped onto,
   and give it a persistent home so it pulls the player back.

**Primary incentive layer: A — Progression** (per-game XP/levels). Streaks (B), crew (C),
and standing/badges (D) are layered as secondary rows, quieter until progression is felt.

## Approach (chosen)

**Getting Started panel** — a persistent, collapsible widget that owns all four incentive
layers as a milestone checklist. It does not interrupt the "there are Ready games, just play"
flow (rejected the full welcome wizard for that reason). The first-run aha stays inline via
the existing auto-starting `answer` tour; the panel carries the retention story.

## Architecture & state

Mostly **derived, barely stored.** A `PlayerOnboarding` context computes milestone states
from data that already exists.

| Milestone | Layer | Source (existing) | Net-new? |
|---|---|---|---|
| Ask your first question | aha | any `QuestionLog` for user | no |
| Reach Level 2 in any game | **A** | `Progress.level_for/1` | no |
| Earn a badge | D | `Curation` badges | no |
| Invite your crew | C | group membership / invite | no |
| Keep a daily streak | B | **new** streak counters | yes |

**Only net-new persisted state:**

- **Streak fields on `users`**: `last_active_on :date`, `current_streak :integer`,
  `longest_streak :integer`. Bumped at the XP-award choke point (`Progress.award_ask/3`),
  one place, already durable.
- **Dismissal / one-time flags**: reuse the existing `tours_seen` pattern — no new column.
  Keys: `"getting_started"` (panel collapsed/complete), `"first_answer_reward"` (one-time card).

**API:** `PlayerOnboarding.summary(user)` → `{milestones, all_complete?, current_streak}`.
One function, callable from any LiveView mount. Pure read except the streak bump, which lives
only at the XP-award choke point.

## UI — the Getting Started panel

Function component `PlayerOnboarding.panel/1` (web). Rendered on **games index** and
**game show** (top of sidebar, above categories). One shared component, two mount points.

**Structure:**

- Header: `Getting Started · 2/5` + collapse caret + progress ring/bar.
- Rows, each: icon · label · one-line "why" · state.
  - **Done** → check + struck label, muted.
  - **Active/next** → highlighted, CTA deep-links to the action:
    - *Reach Level 2* → shows `15/50 XP` mini-bar, button scrolls to ask box.
    - *Invite your crew* → opens crew invite.
    - *Earn a badge* → links to how-voting-works in /help.
  - **Locked/future** → dim, no CTA.
- Footer once `all_complete?`: "You're rolling 🎉 — Level up your table" → crew invite.
  Then auto-collapse + stamp `tours_seen["getting_started"]`.

**Ordering** = locked sequence: aha (first question) → **A progression** (Level 2) → then
B/C/D below. Progression sits directly under the aha row, visually primary (accent, larger);
others stay quiet until progression is done.

**No overlap with the aha:** the existing auto-starting `answer` tour handles
ask→answer→citation. The panel does not re-explain it; the "Ask your first question" row just
checks off when it happens.

**Mobile (hard rule, 390px):** collapsed single-line summary chip by default on coarse-pointer
(`Getting Started 2/5 ›`), expands to a bottom-anchored list on tap. Never pushes the ask box
below the fold.

## Streak mechanic

Kept deliberately dumb. At the XP-award choke point, on each answered question:

- `last_active_on` nil → streak = 1.
- yesterday → streak += 1.
- today → no change (**idempotent**: guards double-award, cache-hit re-runs, Oban retries).
- older → reset to 1.
- always `longest_streak = max(longest_streak, current_streak)`.

Timezone: user's local date if known, else server date. No grace tokens, no freezes (YAGNI).
The streak row just reads `current_streak`.

## First-answer reward moment (sequence payoff)

- Existing level-up confetti stays as-is for real level-ups.
- **New one-time "progression card"** on the very first answered question — not confetti, a
  small card: "First question answered ✓ · +15 XP · Level 1 → 3 answers to Level 2" with a
  subtle bar, dismissible. Fires once ever via `tours_seen["first_answer_reward"]`.
- This is the hinge: answer lands → immediately shows the A-progression ladder. The panel then
  persists that ladder for later visits.
- **Detection:** count of user's answered questions == 1 at award time (already inside
  `award_ask`; one cheap query or existing count). No new state beyond the seen-flag.

## Edge cases & error handling

- **Panel never blocks play.** `summary/1` wrapped so any error → panel silently hidden, page
  renders normally. Onboarding is additive; it never gates the ask box.
- **Existing users** compute as already-done → high completion, auto-collapsed. No forced
  re-onboarding. Streak starts fresh at next answer (nil → 1).
- **Streak bump idempotent** per day.
- **Milestone derivation read-only + cheap** — reuse existing `Progress`/`Curation`/membership
  queries; one summary call per mount; no N+1.
- **Dismissal sticky** via `tours_seen`; re-expandable by caret without un-stamping.

## Testing (only relevant files — no full-suite run)

- Unit: streak transitions (nil→1, +1 consecutive, same-day no-op, gap→reset, longest).
- Unit: `summary/1` milestone flags for fresh vs seasoned user.
- Unit: first-answer card fires exactly once (seen-flag guard).
- Component render: row states (done/active/locked), `all_complete?` footer + auto-collapse.
- Mobile: collapsed chip → expand at 390px (major UI → browser-check per hard rule).

## Deploy

- 1 migration (3 `users` columns: `last_active_on`, `current_streak`, `longest_streak`).
- No data backfill (nil is a valid streak start).
- Help + tours upkeep: add a short "Getting Started / rewards" note to /help per standing rule.
