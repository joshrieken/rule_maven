# Game Feel: Per-Game Mastery — Vertical Slice Design

**Date:** 2026-07-16
**Status:** Approved (brainstorm), ready for implementation plan
**Scope:** One complete progression loop, end to end, for all games. Later phases widen it.

## Goal

Make RuleMaven feel like a video game — more fun, more visually engaging — **without cheapening the product's core promise** (a fast, accurate, cited rules answer at the table). Reward *learning the game and improving answers*, never volume of asks.

## The Feel (approved layering)

- **A — Quiet & trustworthy (everyday):** every qualifying answer earns XP, shown as a small `+N XP` tick and an animated per-game mastery bar in the answer-card footer. Subordinate to the answer; never a takeover.
- **B — Arcade level-up (rare):** on a level-up only, a full-screen banner + confetti, tap to dismiss.
- **C — RPG unlocks (what leveling grants):** crossing a level unlocks tangible things you keep — starting with per-game personas.

These are layered, not exclusive: **A everyday · B for the rare level-up · C for what leveling grants.**

## Progression anchor

Per-game **mastery** is the spine. It rolls up into the existing global economy (see below). Group/table progression and a global-level UI are later phases.

## Economy: ONE currency (Option A)

Do **not** invent a parallel currency. The app already has `users.curator_points` (integer, awarded `+1` in `Games.Curation.settle_votes`, with badge thresholds Curator 10 / Sharp Eye 25 / Taste Maker 5).

- `curator_points` remains the **global** point total (the global-level UI is deferred, but the column keeps accruing).
- A new **per-game mastery bar** shares the same earning events through one funnel.

## Earn model

All XP is per-game mastery XP; qualifying events also bump global `curator_points`.

| Event | XP | Notes |
|---|---|---|
| Ask → **confident, cited** answer that is **new to this user** | base + first-time-topic bonus | cache hit counts if new *to you* |
| Curation that settles right (vote/flag/correction accepted) | large | **deferred to phase 2** (see hooks) |
| Your own repeat question / error / refusal / low-confidence answer | **0** | anti-farm |

**Core principle:** you level by learning the game and improving answers — never by spamming asks. A reward moment **never** renders over a wrong, uncertain, error, or refused answer.

Cut from earlier drafts: play-session streaks (not now); standalone "house-rule contribution" XP (a table variant is not learning the base game, and "correction accepted" is already the curation line — was double counting).

## Data model

Single funnel: **`Progress.award(user, game, event)`** — one function does all four steps atomically:
1. append a `mastery_events` ledger row (unique index enforces per-user dedupe),
2. bump the per-game `game_mastery` rollup,
3. bump global `users.curator_points`,
4. detect level-up + grant unlocks.

`award/3` returns e.g. `{:awarded, %{game_mastery, xp_delta, level_up: bool, unlocked: [voice_id]}}` or `{:duplicate, ...}`.

### New tables (one migration; `Games.UserFavorite` is the join template)

**`mastery_events`** — the ledger. Is simultaneously the anti-farm dedupe, the "recent XP" feed, and the audit trail.
- `user_id`, `game_id`, `source_key` (string), `kind` (string: `"ask"` for the slice), `xp` (int), `inserted_at`
- **unique index `(user_id, source_key)`** — presence of a row = this user already earned for this canonical answer → repeat collides → 0 XP.

`source_key` = the canonical answer / pool id the user landed on (so "new to you" = no prior ledger row with that key for that user; a system cache hit that is new to the user still awards).

**`game_mastery`** — denormalized rollup (the bar + unlocks).
- `user_id`, `game_id`, `xp` (int), `level` (int), `unlocked_voice_ids` (array of ints)
- **unique index `(user_id, game_id)`**

### Alter (same migration)

**`game_voice`** — add `unlock_level` (int, default `0`). `0` = always open.

## Level curve

Pure `Progress.level_for(xp)` with simple rising thresholds, e.g. `50 · n(n+1)/2` → Lv1 @ 50, Lv2 @ 150, Lv3 @ 300 … `award/3` compares old vs new level; a crossing sets `level_up: true` and drives the B moment + any C unlocks.

## Hook points

1. **Ask-new-to-you (slice, now):** in `Workers.AskWorker` immediately after `Games.log_question_update/…` persists (ask_worker.ex:524), **and only if** the answer is confident + cited — reuse the exact guard that decides whether an answer may serve cache. Call `Progress.award/3` with `%{kind: "ask", source_key}`. On `:awarded`, broadcast on the **existing per-question PubSub topic** so LiveView triggers the A tick / B banner. No new realtime plumbing.
2. **Curation-settle (phase 2, deferred):** `Games.Curation.settle_votes` already bumps `curator_points`; routing it through `Progress.award/3` (game_id from the voted question) so it also feeds the per-game bar is deferred to keep the slice to one loop. Global points still accrue in the meantime.

## Unlocks (C)

- `Voices.for_game/1` (voices.ex:335 — currently all personas open) gets a per-user filter: show a persona if `unlock_level == 0` **or** its id ∈ `game_mastery.unlocked_voice_ids`.
- When `award/3` crosses a level, it grants matching `game_voice` ids into `unlocked_voice_ids`.
- A newly unlocked persona is announced in the B banner and then persists in the persona picker with a `NEW` chip, now selectable.

## Rendering & juice

- **A (everyday):** XP tick + mastery bar in the answer-card footer, **below the citation**. Bar animates old% → new% (CSS transition); `+N XP` fades. Per-game title shown (e.g. `Lv 3 · Trader`).
- **B (level-up):** full-screen banner + lightweight CSS/canvas confetti (no heavy dependency), tap to dismiss; fires only on `level_up: true`. Sound off by default.
- **C (unlock):** shown in the B banner and persisted in the picker (`NEW` chip).

## Trust guardrail (non-negotiable)

- B **only** fires on confident + cited answers — same guard as hook #1. **No celebration ever renders over an error, refusal, or low-confidence answer.** This is what makes gamification safe over a rules tool.
- Reward UI is always subordinate to the answer, its citation, and the visible AI-fallibility disclosure — juice never crowds the disclosure out.
- `prefers-reduced-motion` honored everywhere: no confetti, no bar slide — static states instead.
- Mobile-first; verified at 390px; WCAG contrast floors on all new chrome.
- Framed as per-game **learning progress**, not a leaderboard/score — no "ask more" pressure.

## Slice boundary (explicit)

**In:** ask → XP → mastery bar (A) → level-up moment (B) → persona unlock (C), all games; two new tables + one migration; `Progress.award/3` funnel; one live hook site (AskWorker); the `Voices.for_game/1` filter.

**Deferred (later phases):** curation feeds mastery; global-level UI; group/table progression; streaks; unlock types beyond personas (themes, titles); per-game title flavor beyond a generic ladder.

## Testing

- `Progress.award/3`: awards on first-time source_key; returns `:duplicate` (0 XP) on repeat for same user; different user with same source_key still awards.
- Guard: no award (and no B moment) on error/refusal/low-confidence answers.
- `level_for/1`: threshold boundaries.
- Unlock: crossing the unlock level adds the voice id and `for_game/1` then includes it; locked before.
- Concurrency: two near-simultaneous awards for the same `(user_id, source_key)` — unique index yields exactly one row, one XP grant.
- Reduced-motion + 390px render checks for A/B/C.
