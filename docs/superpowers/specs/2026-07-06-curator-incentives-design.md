# Curator Incentives v1 — Design

Date: 2026-07-06
Status: Approved

## Problem

Authors earn reputation when their answers get votes, but voters earn nothing.
There is no incentive to upvote (or downvote) answers, so the trust pipeline is
starved of the vote signal it depends on for promotion and ranking.

## Goal

Reward the *act of good judgment* — voting in the direction the community/admin
eventually confirms — without creating a new gaming surface. Three reward
layers: accuracy points, bonus ask quota, and badges.

## Core concept: vote settlement

A vote **settles** when its answer row reaches a terminal trust event:

| Event | Upvotes settle as | Downvotes settle as |
|---|---|---|
| Promotion to community pool | correct | incorrect |
| Admin `verified` | correct | incorrect |
| Demotion / hidden (moderation) | incorrect | correct |

Rules:

- Each vote settles **at most once, ever**. First terminal event wins; later
  events (e.g. a promoted answer later demoted) do not re-settle or flip
  already-settled votes.
- Only votes **cast before the event** settle. Votes cast after promotion never
  settle — no free points for piling onto already-promoted answers.
- The asker's weight-0 self-confirmation vote is excluded from settlement —
  no self-reward.
- If a user re-votes (changes direction) before settlement, the current
  direction at settlement time is what settles (existing single-row-per-user
  vote model already guarantees this).

## Rewards

Per vote settled `correct`:

- **+1 curator point** (`users.curator_points`). Incorrect settles award 0 and
  carry no penalty — we do not want to discourage voting.
- **Bonus quota:** effective monthly ask quota =
  `base_quota + min(correct_settles_this_month, bonus_cap)` with
  `bonus_cap = 20` (tunable via `RuleMaven.Settings` key
  `curator_bonus_cap`, mirroring other trust tunables). Computed at
  quota-check time from `question_votes.settled_at` in the current month — no
  monthly reset job, no stored counter to drift.
- **Badges** (computed at render time from settled vote counts, no table):
  - **Curator** — 10 correct settles
  - **Sharp Eye** — 25 correct settles
  - **Taste Maker** — 5 correct *upvotes* that were cast before the row
    reached promotion quorum (early spotting; compare `vote.inserted_at`
    against the promotion event time)

## Safety decisions

- `curator_points` is a **separate field from `reputation`** and does **not**
  affect vote weight in v1. A vote ring's payoff is limited to cosmetic points
  and capped bonus quota — no influence gain. Folding curator accuracy into
  vote weight is a possible v2 once we've watched real behavior.
- Existing promotion quorum, per-voter rep caps, account-age gating, and
  vote-ring detection on the moderation dashboard are unchanged and continue
  to gate the events that trigger settlement.
- Ineligible voters (unconfirmed email / young account) still settle and earn
  points; they simply continue not to count toward promotion quorum.

## Data model

Migration:

- `question_votes`: add `settled_at :utc_datetime`, `settled_outcome :string`
  (`"correct"` | `"incorrect"`), partial index on `(user_id, settled_at)
  where settled_outcome = 'correct'` for the monthly quota query.
- `users`: add `curator_points :integer, default: 0, null: false`,
  `curator_seen_at :utc_datetime` (aggregation cursor for the notice UX).

## Mechanics

- **`SettleVotesWorker`** (Oban, unique per `{question_log_id, direction}`):
  enqueued from the three event sites — pool promotion
  (`DirectPromotionWorker` / Games promote path), admin verify toggle, and
  moderation demote/hide (including bulk demotion). It:
  1. Selects unsettled, non-self-confirm votes on the row cast before the
     event timestamp.
  2. Stamps `settled_at` / `settled_outcome` in one `update_all`.
  3. Increments `curator_points` for correct-settled voters.
  4. Reports start/events/finish to the unified Jobs log per convention.
- Settlement is idempotent: the unsettled-only predicate makes re-runs no-ops.

## UX

- **Curator stats panel** in Settings: curator points, correct/total settled
  votes, bonus asks earned this month (x/20), earned badges.
- **Settlement notice:** on next visit with votes settled after
  `curator_seen_at`, show one aggregate flash toast — e.g. "3 of your votes
  were confirmed — +3 points, +3 bonus asks" — then advance `curator_seen_at`.
- Quota display (wherever remaining asks are shown) reflects the bonus.

### Blocker

The 2026-07 audit found the flash never renders (critical, still open). The
toast piece depends on that fix landing first; if it hasn't, fall back to an
inline banner on the Q&A page / settings panel.

## Testing

- Settlement direction correct for all three event types.
- Idempotency: double-enqueue settles once; re-promotion doesn't re-settle.
- Votes cast after the event never settle.
- Weight-0 self-confirm votes excluded.
- Quota math: bonus counts only current-month correct settles, capped at
  `curator_bonus_cap`, cache-hit asks still don't count against base quota.
- Badge thresholds, including Taste Maker's cast-before-quorum condition.
- Points recompute correctly when a settled voter is later suspended
  (suspension does not claw back points in v1 — out of scope, noted).

## Out of scope (v1)

- No penalty for incorrect settles.
- Curator points do not affect vote weight.
- No leaderboard, no streaks, no email digest.
- No point clawback on user suspension or answer un-promotion.
