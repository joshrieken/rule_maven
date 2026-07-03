# Multi-Source Games: Typed Sources, Authority, Citations, Dedup

**Date:** 2026-07-03
**Status:** Approved design, pending implementation plan

## Problem

A game can have several sources (rulebook, learn-to-play guide, FAQ, errata,
player aid). Today they all work, but naively:

- **Ambiguous citations.** Chunks carry bare `[Page N]` markers; an answer's
  "page 5" doesn't say *which* source's page 5. `Citations.valid?/3` validates
  the page against the pooled chunks of all sources.
- **No conflict policy.** A simplified how-to-play guide or an errata sheet can
  contradict the rulebook; the model gets all chunks flat with no signal about
  which source wins.
- **Retrieval crowding.** Overlapping sources (guide restates rulebook,
  expansion reprints base rules) produce near-duplicate chunks that crowd out
  distinct material within the 6-chunk retrieval budget.
- **Weak source semantics in prep.** Documents have only a free-text `label`
  and a vestigial `is_core` boolean.

Expansion asks already work (game show page has per-expansion include toggles
feeding `retrieve_chunks_for_games([game.id | expansion_ids])`) but have the
same flat-pool problems, plus a second conflict axis: expansion rules override
base rules for expansion content.

## Decisions (made during brainstorming)

1. **Typed authority order** — fixed hierarchy from a per-document `kind`, no
   per-game configuration.
2. **Readiness unchanged** — every uploaded source must complete the required
   pipeline and an admin must approve publish (both already true). Which
   sources are "necessary" stays the admin's call.
3. **Expansion toggles stay opt-in** — expansions change rules, so including
   an unowned expansion by default could corrupt base-game answers.

## Design

### 1. `Document.kind`

New string field on `documents`, picked at upload, editable on the source row.
Fixed authority order, high → low:

| Kind | Covers |
|------|--------|
| `errata` | Official errata, corrections, living-rules changelogs |
| `faq` | Official FAQ, rulings, designer clarifications |
| `rulebook` | Core rulebook, rules reference, living rules PDF |
| `scenario` | Scenario/campaign/adventure books, mission packs |
| `howto` | Learn-to-play, quickstart, tutorial booklet |
| `reference` | Player aids, quick-reference cards, turn summaries |
| `notes` | Designer notes, almanac, lore companions |
| `other` | Anything unofficial (admin's discretion) |

- Expansion rulebooks are `rulebook` on the expansion's game row (expansions
  are separate games), not a kind.
- FFG-style splits: Learn to Play → `howto`, Rules Reference → `rulebook`.
- Migration: existing documents default to `rulebook` (nearly all current
  uploads are rulebooks); admins can retype. `is_core` is dropped (UI toggle
  and field) — `kind` subsumes it.

### 2. Conflict policy (two axes)

Stated in the ask prompt (via the Prompts registry — never hardcoded):

1. **Kind authority:** errata > faq > rulebook > scenario > howto > reference
   > notes > other.
2. **Game specificity:** within the same kind, an expansion's source overrides
   the base game's *for content involving that expansion*.

The model answers from the highest-authority source and may note the
contradiction ("The rulebook says X, but the FAQ clarifies Y").

### 3. Prompt assembly

`retrieve_chunks_for_games/3` returns source metadata with each chunk
(document id, label, kind, game name, base-or-expansion). Context assembly in
`LLM.call_llm/7` groups chunks under headers instead of a flat `---` join:

```
=== BASE GAME "Ethnos: 2nd Edition" — RULEBOOK "MP24 ETHNOS rulebook" ===
[Page 5] ...chunk...

=== EXPANSION "Ethnos: X" — ERRATA "X errata v1.2" ===
[Page 2] ...chunk...
```

The system prompt template gains the authority rules and instructs the model
to cite source + page.

### 4. Citations

- Answer JSON gains a `cited_source` (the source label) next to `cited_page`.
  `QuestionLog` stores it (new column).
- `Citations.valid?` becomes source-scoped: the cited page must exist among
  the *cited source's* chunks and the passage must be grounded in them.
  Fallback when the model omits the source: current pooled behavior.
- User-facing display: source label + page ("Rulebook, p. 5 · FAQ, p. 2"),
  with the expansion's game name prefixed for expansion sources. Labels only —
  consistent with the no-PDF-access copyright rule.

### 5. Retrieval dedup

In `retrieve_chunks_for_games/3`: over-fetch (2× limit), collapse
near-duplicates (cosine similarity of stored embeddings above a threshold,
tuned during implementation), keep the higher-authority copy — tie broken
toward the base game (canonical text) — then trim to the limit. Pure
Elixir-side post-processing; no schema or pgvector query changes.

### 6. Prepare page UX

- Kind picker on the upload form (default `rulebook`) and on each source row
  (replaces the `is_core` toggle).
- Kind badge on source rows.
- Readiness ladder, publish gate, per-source pipeline: unchanged.

### 7. Multi-parent expansions

An expansion can be supported by several base games (e.g. a promo compatible
with both the 1st and 2nd edition). The single `parent_game_id` FK can't
express that; BGG itself models expansion → multiple bases.

- New join table `game_expansion_links` (`expansion_id`, `base_game_id`,
  unique pair, FKs `on_delete: :delete_all`).
- Migration backfills existing `parent_game_id` rows into the join table,
  then drops the column (and the `belongs_to :parent_game` /
  `has_many :expansions` schema associations in favor of join-backed
  queries).
- **Population:** BGG enrich/sync parses every "expands" link from
  `bgg_data` and creates links to catalog games matched by `bgg_id`;
  unmatched links are ignored until that edition is imported. Admins can
  add/remove links manually on the game editor.
- **Ask flow:** a base game's show page offers toggles for every linked
  expansion that has documents (`expansions_with_documents` reads the join).
  The same expansion appears under each linked edition with one shared set
  of documents. Retrieval is unchanged — it already takes an explicit id
  list.
- **Prompt/citations:** unaffected. An ask happens in one base game's
  context, so the "EXPANSION" grouping and citation labels stay as specced.
- Implementation order: this lands **first** — it's data-model groundwork
  the rest builds on.
- Blast radius to audit during planning: BGG import/enrich workers,
  `expansions_with_documents`, catalog + game editor UI, every
  `parent_game_id` call site.

## Out of scope

- Per-game authority overrides (rejected: fiddly).
- Default-on expansions / collection-driven defaults (rejected: expansions
  change rules; opt-in stays).
- Scenario-scoped retrieval (asking "in scenario 3…" filters to that book) —
  future work; `kind` makes it possible later.
- Source versioning (rulebook v1.1 replacing v1.0) — admins delete/re-upload.

## Testing

- Expansion links: backfill migration, BGG link parsing (multi-base, unmatched
  bgg_ids ignored), `expansions_with_documents` via join, shared expansion
  visible under both editions.
- `kind` validation + migration default.
- Prompt assembly: grouping headers, authority text present, expansion
  sources labelled with their game.
- `Citations.valid?`: source-scoped pass/fail, pooled fallback when
  `cited_source` missing.
- Dedup: near-duplicate collapse keeps higher authority; base beats expansion
  on tie; budget still filled with distinct chunks.
- Regression: single-source games behave exactly as today (one group header,
  same citations shape with the fallback path).
