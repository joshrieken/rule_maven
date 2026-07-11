# Living Google Doc Rulebook — Design

**Date:** 2026-07-10
**Status:** Approved (design), pending implementation plan

## Problem

A game's core rulebook is a **public Google Doc** that the third-party author edits
occasionally and unannounced (but maintains a changelog). The app's ingestion model
assumes an upload ingested once. We need to keep chunks + embeddings + the pooled
answer cache in sync with a doc that changes underneath us — **without nuking the
entire answer pool on a minor edit**.

## Constraints & context

- Doc is **public**, fetchable without auth via export URLs
  (`.../export?format=txt|html`).
- Edits are **rare and unannounced**; a human-readable changelog exists in the doc.
- This doc is the **sole authority** (core rulebook), not one source among several.
- Existing pipeline: upload → chunk → embed → RAG ask, with a pooled-answer cache
  and content-staleness invariants.

## Current behavior (why it's the full-nuke we're avoiding)

- **Provenance already exists** (good): `questions_log.source_chunk_ids
  {:array, :integer}` records which chunks each answer cited; a `stale` boolean
  already gates the cache.
- **Re-chunk is delete-all + insert-all** (`games.ex:~3705`):
  `Repo.delete_all(chunks)` then `insert_all(new)`. Every chunk gets a fresh serial
  ID and the whole doc re-embeds → old `source_chunk_ids` dangle.
- **`mark_stale_for_game`** (`games.ex:~1195`) demotes *every* pooled answer and
  stales *every* row in the game, ignoring `source_chunk_ids`. This is the
  typo-nukes-everything behavior.
- **Chunking is fixed 500-char per `\f` page break** (`games.ex:~3667`). A Google Doc
  has no page breaks → one blob → a one-word edit shifts every downstream 500-char
  boundary, so even naive content-diffing would mark most chunks dirty.

## Design

Three cooperating changes, plus an ingestion wrapper.

### 1. Stable chunk identity (upsert by content hash)

Replace delete-all/insert-all with an identity-preserving reconcile:

- Compute a `content_hash` per new chunk (stored on `chunks`).
- **Unchanged** chunk (same hash present) → keep the existing row: **ID and
  embedding intact**, no re-embed.
- **New/changed** chunk → insert new row, enqueue embed for only these.
- **Removed** chunk (old hash absent from new set) → delete row.
- The reconcile returns a **`dirty_chunk_ids`** set = inserted ∪ deleted ∪ changed.

Chunk gets a new field: `content_hash :string` (indexed per document). Identity is
`(document_id, content_hash)`; `chunk_index` still stored for ordering but is not the
identity key (it shifts).

### 2. Heading-anchored chunking for live Google Docs

For live-source docs, fetch **HTML** (`export?format=html`), split on heading
elements (`<h1>`–`<h3>`) into section blocks, then 500-char sub-chunk *within* a
section. Effect: an edit inside "Combat" only re-hashes Combat's chunks; boundaries
elsewhere are unchanged. `section_label` (already detected today) becomes the
heading path.

Non-live uploads keep the existing page-based chunker unchanged.

### 3. Scoped invalidation

New `Games.mark_stale_for_chunks(game_id, dirty_chunk_ids)`:

- Postgres array overlap: `where: fragment("? && ?", q.source_chunk_ids,
  ^dirty_chunk_ids)`.
- For matched rows only: set `stale: true`, `pooled: false`; community rows also
  `needs_review: true` (mirroring the scoped subset of `mark_stale_for_game`
  semantics).
- Also scope the persona-restyle clear (`Voices`) and house-rule staleness to the
  affected answers where feasible; game-wide clear is acceptable v1 if per-answer is
  costly (documented trade-off).

The daily poll calls **this**, never `mark_stale_for_game`. Full-game staleness stays
reserved for wholesale re-ingest / moderation.

### 4. Ingestion wrapper (live sync)

- **Document model:** add `live_source :boolean` (default false), reuse existing
  `source_url` for the export URL, add `content_hash :string` (last synced doc hash)
  and `synced_at :utc_datetime`. `kind` stays `"rulebook"` — live-ness is orthogonal
  to type.
- **Attach flow:** admin/owner pastes the public doc URL → validate it's
  publicly fetchable → initial fetch + chunk + embed (first snapshot).
- **`GoogleDocSyncWorker` (Oban, daily cron):** for each `live_source` doc:
  1. Fetch `export?format=html`.
  2. Normalize + hash whole-doc content. If equal to `content_hash` → **no-op**
     (the cheap common case; edits are rare).
  3. If changed → run the reconcile re-chunk (§1/§2) → `mark_stale_for_chunks`
     with the returned `dirty_chunk_ids` → update `content_hash`, `synced_at`.
  4. Reports to the unified Jobs log (per job-log convention).
- **Manual "Re-sync now"** button (backstop for someone who spots the changelog)
  runs the same worker path immediately.
- **Changelog surfacing:** store `synced_at`; show a user-facing "Rulebook updated
  {date}" label on the game. (Parsing the changelog *content* is out of scope v1 —
  detection is by content hash, not by trusting the author's changelog.)

## Data flow

```
daily cron ─▶ GoogleDocSyncWorker
                 │ fetch export?format=html
                 │ normalize + hash
                 ├─ hash == stored ─▶ done (no-op)
                 └─ changed
                     │ reconcile re-chunk (upsert by content_hash, heading-anchored)
                     │   └─▶ dirty_chunk_ids
                     │ embed dirty chunks only
                     │ mark_stale_for_chunks(game_id, dirty_chunk_ids)
                     │ update content_hash, synced_at
                     └─ Jobs log entry
```

## Error handling

- **Fetch failure / non-200 / doc went private:** worker logs to Jobs, leaves last
  good snapshot serving, retries next cycle. Surface a "sync failing" admin flag
  after N consecutive failures.
- **Empty/degenerate fetch** (near-zero content): treat as failure, do **not**
  reconcile (guard mirrors the existing `blank_page_text?` protection — never let an
  empty fetch wipe chunks).
- **Reconcile atomicity:** chunk upsert/delete + embed enqueue in a transaction; a
  mid-reconcile failure must not leave the doc with partial chunks or lost provenance.
- **Embed lag:** dirty chunks may be briefly un-embedded; retrieval tolerates missing
  vectors (skip un-embedded chunks) rather than erroring.

## Testing

- **Reconcile identity:** unchanged content re-chunk → zero dirty ids, embeddings
  untouched (assert same chunk IDs + vectors).
- **Minor edit:** change one heading section → only that section's chunk IDs dirty;
  a `git stash`-style baseline confirms untouched chunks keep IDs.
- **Scoped stale:** answer citing an untouched chunk stays `pooled`/non-stale; answer
  citing a dirty chunk goes stale + demoted. (Per testing-lesson memory: confirm the
  test FAILS against current `mark_stale_for_game` before wiring the scoped path.)
- **No-op poll:** unchanged doc → worker does zero writes, zero embeds.
- **Fetch failure / empty fetch:** last snapshot preserved, no chunk loss.
- **Heading chunker:** HTML with headings → section-anchored chunks, `section_label`
  = heading path.

## Out of scope (v1)

- Parsing changelog text to target invalidation (content-hash diff is source of truth).
- Non-public docs / OAuth / Drive API.
- Multi-source live docs (this is the sole-authority core rulebook).
- Real-time push (Google has no webhook for public docs; daily poll suffices for rare
  edits).

## Deploy notes

- Migrations: `chunks.content_hash` (+ index), `documents.live_source /
  content_hash / synced_at`.
- Oban cron entry for `GoogleDocSyncWorker` (daily).
- Backfill: existing uploaded rulebooks get `content_hash` on next re-chunk;
  `live_source` defaults false, no behavior change for them.
