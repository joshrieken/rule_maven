# Rulebook Coverage Engine — Design

**Date:** 2026-07-16
**Status:** Approved, pre-implementation
**Scope:** Measurement foundation only. Contribution incentives (per-game titles,
personal credit, browsing-counts, UI meters) are a **separate follow-up spec** that
builds on this engine.

## Problem

We want a shared, per-source "rulebook coverage" signal — what fraction of a game's
rulebook (and its other sources) has a grounded answer behind it — so players can later
see gaps and feel like they're contributing by filling them. Nothing measures this today.

This spec builds the **measurement engine only**: harden the answer→source link, record
which pages are covered, and expose coverage % + a gap list. The reward layer (who gets
credit, titles, whether browsing counts) is deliberately out of scope and specced later.

## Denominator decision (settled)

**Page is the only stable enumerable grain.** Sections are infeasible now (`section_label`
is regex-derived, sparse, nullable, absent from citations); chunk ids churn on every
re-extract (`games.ex:4401` delete_all + insert_all). Named sections are a planned **Phase B**
that layers *on top of* pages (a section = a named page-range), so page-grain here is not a
dead end — it's the substrate B reuses.

Coverage % per document = `distinct covered pages ÷ page_count`. Rolled up per game =
`sum(covered) ÷ sum(page_count)` across the game's **published** documents.

## Load-bearing facts (verified in code)

- `question_log` **already has a `belongs_to :document` FK** (`question_log.ex:93`) — it is
  **never populated** at creation (`show.ex:2497`). Hardening reuses this column; no new
  column on `questions_log`.
- Citations are stored as `{:array, :map}` of `%{"quote","page","source"}` where `source`
  is a document **label string**, matched to `documents.label` via `canonical_source/2`
  (`ask_worker.ex:1119`). No `document_id` per citation today.
- `documents.page_count` exists (`document.ex:108`) but **is not always populated**. Must
  handle nil.
- `documents.status`: `pending_review` (default) / `published`. `kind`: rulebook, errata,
  faq, scenario, howto, reference, notes, other.
- `source_chunk_ids` is a declared column that is **never written** — do not rely on it.

## Architecture

### 1. Citation hardening (the foundation)

At answer-persist time in `AskWorker`, resolve each citation's label to a real
`documents.id`. `canonical_source/2` already computes the matched label; extend that path to
also return the document id. Then:

- Write `document_id` into each citation map: `%{"quote","page","source","document_id"}`.
- Populate the scalar `question_log.document_id` from the **primary** citation's document.
- Keep all label fields as-is (backwards-compatible; existing UI keeps showing source names).

Every answer's citations now carry a stable `(document_id, page)` key. This key is what the
entire engine joins on — no more fuzzy label matching downstream.

### 2. Coverage storage — page-grain table

New table `document_page_coverages`:

| column | type | notes |
|---|---|---|
| `document_id` | FK → documents, `on_delete: :delete_all` | |
| `page` | integer | |
| `first_covered_by_user_id` | FK → users, nullable | who first grounded this page |
| `first_question_log_id` | FK → questions_log, nullable | the answer that first covered it |
| `first_covered_at` | utc_datetime | |
| unique index | `(document_id, page)` | one row per covered page |

Rows are **upserted `ON CONFLICT DO NOTHING`** — first writer wins, later re-covers are
no-ops. Idempotent under re-ask / retry / cache-hit / Oban retry. This idempotence is the
anti-grind property: clicking many questions about the same page never inflates coverage.

Rationale for page-grain over a denormalized `covered_pages int[]`: the gap list is a trivial
complement, upserts are idempotent, **and it records who first covered each page** — the
exact hook the Phase-2 contribution/title layer will need. One small table, one upsert per
answer.

### 3. Coverage context — `RuleMaven.Coverage`

Pure reads plus the one write path.

- `record_citations(question_log)` — write path. Called from `AskWorker` in the same
  post-answer flow that already awards mastery. Extracts distinct resolvable
  `(document_id, page)` pairs from the citation array and upserts coverage rows. Idempotent.
- `for_document(document_id)` → `%{page_count, covered, pct}`. `page_count` nil → `pct: nil`
  ("coverage pending"), never divide by nil/zero.
- `for_game(game_id)` → `{per_source_list, rollup}` where rollup =
  `%{covered, total, pct}` across **published** documents only (`status == "published"`;
  `pending_review` excluded so unreviewed uploads don't dilute the meter).
- `gaps(document_id)` → uncovered page numbers (`1..page_count` minus covered set). Engine
  returns bare page numbers; label/snippet enrichment is deferred to the Phase-2 UI spec.

Reads are indexed counts on a small table. Add the existing ETS cache pattern only if a hot
path proves it necessary — not upfront (YAGNI).

## Data flow

```
ask answered
  → AskWorker builds citations, resolves label → document_id (hardening)
  → persists question_log (citations carry document_id; scalar document_id set)
  → Coverage.record_citations(question_log)
       → distinct (document_id, page) → upsert document_page_coverages (ON CONFLICT DO NOTHING)
game page loads
  → Coverage.for_game(game_id) → per-source % + rollup %
  → Coverage.gaps(document_id) → uncovered pages (for later gap UI)
```

## Recompute / backfill

- **Live:** `record_citations/1` keeps coverage current going forward.
- **Backfill:** a one-shot `mix rule_maven.backfill_coverage` (or Oban job) walks existing
  `questions_log` rows with citations, resolves label→document_id via the same
  `canonical_source` logic, and upserts coverage. Idempotent — safe to re-run. Seeds the
  corpus that predates hardening.
- **Re-extract invalidation:** when a document is re-extracted and `page_count` shrinks,
  prune coverage rows with `page > new page_count`; `pct` recomputes from the new
  denominator. Covered page numbers are otherwise stable, so surviving rows stay valid.
- **Document delete:** `on_delete: :delete_all` removes coverage rows with the document.

## Edge cases & error handling

- **`page_count` nil** → `pct: nil`, surfaced as "coverage pending", never 0%. No divide-by-zero.
- **Citation page present but label unresolvable** (no matching document) → no coverage row
  (can't attribute to a denominator). Logged, non-fatal.
- **Citation page > `page_count`** (bad page number) → skip/clamp; `covered` never exceeds
  `page_count`, so `pct` never exceeds 100%.
- **Non-rulebook kinds** (errata/faq/scenario) count toward coverage when they have a
  `page_count`; the rollup spans all published docs — honest corpus coverage.
- **Coverage never blocks play.** Any error in the context → the caller renders normally;
  coverage is additive, never a gate.

## Testing (only relevant files — no full-suite run)

- Unit `record_citations/1`: distinct-page extraction, idempotent upsert, unresolvable
  label skipped, page > page_count clamped.
- Unit `for_document/1` / `for_game/1`: pct math, nil page_count → nil pct, published-only
  rollup.
- Unit `gaps/1`: correct complement of the covered set.
- Unit `AskWorker` hardening: writes `document_id` on each citation + scalar
  `question_log.document_id`.
- Backfill task: seeds coverage from existing rows; idempotent re-run leaves counts stable.
- Tee test output to `./tmp` per standing rule; run only these files.

## Deploy

- 1 migration: `document_page_coverages` table + `(document_id, page)` unique index +
  supporting FKs. (`question_log.document_id` column already exists — not created here.)
- Run `mix rule_maven.backfill_coverage` once after migrate.

## Explicitly out of scope (follow-up spec)

Per-game **titles / status**, *who gets credit* for filling a gap, whether **browsing**
(not just asking) earns credit, personal attribution UI, the visible coverage **meters** and
**gap to-do list**, and **Phase B named sections**. This spec delivers only the measured
coverage + gap data those features will consume.
