# Contribution Incentives — Design

**Date:** 2026-07-19
**Status:** Approved, pre-implementation
**Builds on:** the Rulebook Coverage Engine (Phase A, merged) — `RuleMaven.Coverage`,
`document_page_coverages` (page-grain community coverage, `first_covered_by_user_id`).

## Problem

The Coverage Engine measures rulebook coverage but nothing surfaces it. Players can't see
the shared corpus filling in, can't tell what's missing to contribute, and get no personal
status for engaging with a game's rules. This spec adds the **reward layer** on top of the
engine: a shared community coverage meter, an actionable gap to-do list, and a personal
per-game title.

## Decisions (locked in brainstorming)

- **Two tracks (C).** A shared **community coverage meter** ("what the group has grounded")
  AND a personal per-game **title** ("what you've engaged with"). They coexist and share the
  page grain — community = "us", personal = "you".
- **Personal title = personal page-coverage** — the distinct rulebook pages you've either
  **asked about** or **read** (viewed a grounded answer citing them). Includes browsing,
  dedupes by page, honors "levels = real coverage, not cosmetic XP".
- **Generic per-game title tiers**, name = `"<Game> <Tier>"`:
  `< 25%` none · `≥ 25%` Student · `≥ 50%` Scholar · `≥ 75%` Expert · **Sage** = your set
  covers 100% of the *community-covered* pages (reachable; raw 100% is not, since cover/art
  pages are never cited). Lower tiers use raw personal %.
- **Reading counts (A).** Viewing a grounded answer stamps its cited pages to your personal
  coverage.
- **Gaps snippet-enriched now (A).** Each uncovered page shows a first-line/heading snippet
  from that page's existing chunk text — no LLM, no Phase B dependency.

## Architecture & data model

- **New table `user_page_coverages`**: `(user_id, document_id, page)` unique + timestamps.
  Your personal page-exposure set. Upserted `ON CONFLICT DO NOTHING`. FKs
  `on_delete: :delete_all` (user or document deletion clears rows).
- **`document_page_coverages`** (community) — unchanged; already shipped.
- **Titles derived, never stored** — computed from personal coverage vs the community-covered
  set. No title column, no staleness.

Load-bearing facts (verified): `chunks` has `page_number`, `content`, `section_label`
(sparse) — enough for gap snippets. `mastery_hud` lives at `sub_bar.ex:82/97` — the title's
home. Grounded answers render into `@conversation` in `game_live/show.ex`.

## Context — extend `RuleMaven.Coverage`

New schema `RuleMaven.Coverage.UserPageCoverage` (table `user_page_coverages`).

- `record_personal(user_id, citations)` → `{:ok, count}` — upsert your `(document_id, page)`
  from a grounded answer's citations. Reuses the exact clamp/skip/idempotence rules and the
  `Map.fetch` unknown-document guard from `record_citations/1` (extract the shared
  `covered_pair` logic so both paths use it — DRY).
- `personal_for_game(user_id, game_id)` → `%{covered, total, pct}` — your coverage across the
  game's published documents + expansions, using the **same denominator** as `for_game/1` so
  the personal and community bars are directly comparable. nil `page_count` ⇒ `pct: nil`.
- `title_for(user_id, game_id)` → `%{tier, label, pct, next_tier, pages_to_next}` — tier from
  personal pct (25/50/75) with **Sage** when the personal page set ⊇ the community-covered
  page set (and that set is non-empty). `label = "<Game> <Tier>"`. `nil` tier below 25%.
- `gaps_enriched(game_id)` → `[%{document_id, page, label, snippet}]` — uncovered pages
  (from `gaps/1` per document across the game) each enriched with a snippet: prefer the
  page's `chunks.section_label` if present, else the first line of the lowest-`chunk_index`
  chunk on that `page_number`. Uncovered-only, ordered by document then page.
- `contribution_credit(user_id, game_id)` → integer — count of `document_page_coverages` rows
  across the game's published docs where `first_covered_by_user_id == user_id` ("you were
  first to ground N pages").

All reads are indexed and cheap; wrap in the existing ETS cache pattern only if a hot path
proves it (YAGNI).

## Instrumentation — single write point

Personal coverage is fed at **one place: the answer-view path** in `game_live/show.ex`.
When a grounded answer becomes visible to a logged-in user — their own just-answered ask or a
browsed community answer opened from the corpus — stamp its cited `(document_id, page)` pairs
via `record_personal(user_id, citations)`.

- One point avoids double logic: the asker sees their own answer through the same render path,
  so no separate hook in `ask_worker`.
- **Best-effort** (wrapped in try/rescue, non-blocking) — never delays or breaks the render.
- **Logged-out users**: skip (no personal track).
- The community write (`Coverage.record_citations` in `ask_worker`) stays exactly as shipped.

The exact handler: the point where a grounded answer (own result or an opened browsed
question) is assigned into `@conversation`. The implementation plan pins the precise
function; conceptually it is "a grounded answer just became visible to this user".

## UI (mobile-first, 390px hard rule)

1. **Community coverage meter** — game-show sidebar (`.question-sidebar`). Per-game % bar +
   per-source breakdown (e.g. Rulebook 60%, Expansion 20%). Below it, an expandable
   **"Help fill the gaps"** panel = `gaps_enriched` (snippet-labeled uncovered pages, each a
   nudge to ask about that topic). A one-line contribution credit:
   "You were first to ground N pages" (`contribution_credit`).
2. **Personal title** — beside the existing `mastery_hud` in `sub_bar.ex`:
   `"Catan Scholar"` + a personal-coverage mini-bar + next-tier progress
   ("3 more pages to Expert", from `title_for`).
3. Shared visual language — one bar component, community accent = "us", personal accent =
   "you", so the two read distinctly at a glance.

Follows existing sidebar/sub-bar patterns; no new layout primitives.

## Edge cases & error handling

- **nil `page_count`** → personal pct nil, title "—" (coverage pending). Never divide by zero.
- **Anti-grind** → unique `(user_id, document_id, page)`; re-reads/re-asks are no-ops; page
  clamped to `page_count`.
- **View stamping best-effort** → any error logs; render proceeds.
- **Sage with empty community set** (fresh game) → unreachable; lower tiers still work on raw %.
- **Title/meter derivation cheap** → one `personal_for_game` + one community read per mount.
- **Coverage never gates play** — every read wrapped; failure → surface hidden, page renders.
- **Ungrounded/refused answers** carry no citations → stamp nothing (consistent with engine).

## Testing (only relevant files — no full-suite run)

- Unit: `record_personal` idempotent, clamp, distinct-page dedup, unknown-document skip.
- Unit: `personal_for_game` pct + denominator parity with `for_game/1`.
- Unit: `title_for` tier boundaries (24/25/49/50/74/75%), Sage = full community set, empty-
  community edge, nil page_count → "—".
- Unit: `gaps_enriched` pulls snippet from chunk text/section_label, uncovered pages only.
- Unit: `contribution_credit` counts only this user's first-covered pages in the game.
- Instrumentation: viewing a grounded answer stamps the VIEWER's pages, not other users';
  logged-out view stamps nothing.
- Component: meter + gap list render; title beside HUD; **390px mobile check** (major UI →
  browser-verify per hard rule).
- `/help` + tours upkeep: add a short "coverage & titles" note (user-facing, per standing rule).

## Deploy

- 1 migration (`user_page_coverages` + unique index + FKs).
- No backfill (personal coverage accrues going forward; seeding from historical askers' own
  citations is deliberately skipped — YAGNI).

## Out of scope (later)

Phase B named sections (upgrades gap labels from page-snippet → real section names);
cross-game/global title aggregation; leaderboards; any change to the community engine itself.
