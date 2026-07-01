# Deferred Rulebook Extraction

## Problem

Every rulebook ingest path — file upload, URL download, BGG download — runs
`DownloadWorker`, which fetches/copies the file and *immediately* extracts text
(`ingest_saved_pdf`), then creates a fully-processed `Document` (chunks,
cheatsheet, auto-publish). Extraction is the most expensive/slow step (per-page
vision + critic), and the admin has no chance to decide when to spend it. The
admin wants to upload a rulebook, land on the prepare page, and trigger
extraction there deliberately.

## Goal

Decouple **ingest** (save the source file + metadata) from **extraction** (fill
the document's page text). Extraction becomes a step run from the prepare page —
both via a dedicated "Extract" button and as the first step of the one-click
"Prepare" auto-pipeline. All ingest paths (upload / URL / BGG) defer extraction.

## Non-goals

- Changing the extraction algorithm itself (vision reader, critic, gate).
- Changing cleanup / embed / enrichment behavior.
- Non-PDF native formats (docx/xlsx) — same save-only treatment, no special work.
- Migrating existing already-extracted documents (they stay as-is).

## Current State (for reference)

- `RulebookDownloader.download/4`, `find_and_download`, `ingest_local/4` all funnel
  into `ingest_saved_pdf/5`, which: extracts text → paginates → `create_document`.
- `Games.create_document/1` (after the `file_hash` dedup guard) chunks the doc,
  invalidates the pool, enqueues the cheatsheet, and auto-publishes when
  `quality_ok?`.
- `Readiness` models the required ladder `source → extract → review → cleanup →
  embed`. `doc_extracted?` = `pages != [] and all pages have non-empty text`, so
  a document with `pages: []` already reads as "source present, not extracted."
- `Readiness.drive/1` currently **pauses** with `needs_extract` when extract is
  incomplete (it never actually runs extraction — upload pre-extracts today).
- `DownloadWorker` runs per game (`unique` on `game_id`), reports to the Jobs log,
  and broadcasts `{:download_done, …}`.

## Design

### 1. Ingest = save-only (`RulebookDownloader`)

Split `ingest_saved_pdf/5` into two functions:

- **`save_source/5`** `(game, pdf_path, url, label, on_progress)` — no extraction.
  Computes `file_hash`/`file_size`/`content_type`, then `Games.create_document`
  with `pages: []`, `full_text: nil`, and the file metadata. Returns `{:ok, doc}`.
- **`extract_document/2`** `(document, on_progress)` — the current extraction tail:
  `extract_with_cleanup(pdf_path, …)` → `paginate` → `attach_page_meta` →
  `Games.update_document(doc, %{pages:, full_text:, from_ocr:, page_count:,
  printed_offset:, extracted_at:})`. Returns `{:ok, doc}` or `{:error, reason}`.

`download/4`, `find_and_download`, and `ingest_local/4` call **`save_source`**
only (they no longer extract).

### 2. `Games.create_document/1` guard

An unextracted document (`pages: []`, empty text) must **not** chunk, enqueue the
cheatsheet, or auto-publish. Empty text already fails `quality_ok?` (→
`pending_review`), but the chunk/cheatsheet side effects run unconditionally
today. Gate the post-insert side effects on the document actually having text:

```
extracted? = (attrs full_text is a non-empty string)
if extracted?, do: chunk + invalidate_pool + cheatsheet, else: skip
```

`invalidate_pool` still runs on a real (extracted) create/update as before. The
`file_hash` dedup guard is unchanged.

### 3. `Workers.ExtractWorker` (new)

Durable Oban worker, `unique` per `document_id`, `max_attempts: 3`, timeout-guarded,
reporting to the Jobs log (`start_run/event/finish_run`, kind `"extract"`).

`perform`:
1. Load the document (no-op + close run if it vanished).
2. `RulebookDownloader.extract_document(doc, on_progress)`.
3. On `{:ok, _}`: finish run `done`; broadcast on the document/game Jobs topic;
   call `Readiness.advance(doc.game_id)` so the pipeline continues.
4. On `{:error, reason}`: finish run `failed`; leave the doc unextracted so the
   pipeline stays paused at `needs_extract` and the prepare page can offer retry.

A `Games.enqueue_extract(document)` / `Workers.ExtractWorker.enqueue(doc)` helper
(no-op in test, like the other workers) wraps insertion. An `extract_running?/1`
predicate mirrors the existing `cleanup_running?/1` (query Oban for an active
job for the doc) so the pipeline and UI don't double-enqueue.

### 4. `Readiness.drive/1`

Replace the `not step_complete?(:extract, …)` **pause** branch with a **run**
branch, mirroring `run_cleanup`:

```
not step_complete?(:extract, game, docs) ->
  run_extract(docs)     # enqueue ExtractWorker for each unextracted, not-in-flight doc
  clear_pause(game)
  {:running, :extract}
```

`run_extract/1` skips docs already extracted or with an extract job in flight.
The `needs_extract` pause still exists for the **failure** case (ExtractWorker
errored, doc still unextracted, auto disarmed) so the prepare page can show it.

### 5. Prepare page (`GameLive.Prepare`)

- Add `handle_event("extract", _, socket)` (admin-gated): enqueue `ExtractWorker`
  for the game's unextracted documents, `load()`, flash "Extracting…". Progress
  streams over the already-subscribed document/game Jobs topic and lights up the
  extract step's "Running…" indicator (add `"extract" => :extract` to
  `@kind_to_step`).
- `step_action/2`: for `%{id: :extract, state: :todo}` return an **Extract**
  action that triggers the `extract` event (a `phx-click` button rather than a
  link). The existing per-step render must render this as a button.
- `pause_message(needs_extract)`: add an **Extract now** button alongside the
  message.

### 6. Upload / redirect (`GameLive.Form`)

- `process_uploads` and the form-save upload branch: after enqueuing
  `DownloadWorker` (now save-only), `push_navigate` to `/games/:id/prepare`
  instead of staying on the edit Manage tab.
- No `DownloadWorker` API change — it saves the source and no longer extracts.

## Data Flow

```
upload/URL/BGG
  → DownloadWorker (save_source)  → Document(pages: [])   → redirect /prepare
  → admin clicks "Extract"  (or "Prepare" auto-pipeline)
  → ExtractWorker → extract_document → update_document(pages, full_text)
  → Readiness.advance → cleanup → embed → enrichments
```

## Error Handling

- Extract failure: Jobs run `failed`, doc stays `pages: []`, pipeline auto
  disarms and shows `needs_extract`; the Extract button re-runs it (idempotent —
  `update_document` overwrites).
- File missing on disk at extract time: `extract_document` returns `{:error, …}`
  → same failure path.
- Double trigger (button spam / auto + button): `unique` per `document_id` +
  `extract_running?/1` guard collapse to one job.

## Testing

- `Games.create_document/1`: with `pages: []` / empty text → no chunks created,
  status `pending_review`, not auto-published; the `file_hash` dedup still holds.
- `RulebookDownloader.save_source/5`: creates a `Document` with `pages: []` and
  the file metadata, without invoking extraction.
- `Workers.ExtractWorker`: given a doc with a `pdf_path` and empty pages and a
  mocked extractor, fills `pages`/`full_text` via `update_document` and calls
  `Readiness.advance`.
- `Readiness.drive/1`: an unextracted doc yields `{:running, :extract}` (job
  enqueued) rather than `{:paused, "needs_extract"}`; a failed/unextracted doc
  with auto off still reports `needs_extract`.

## Rollout

Pure code change, no data migration. Existing extracted documents are unaffected
(their pages are non-empty → `doc_extracted?` true → pipeline skips extract).
