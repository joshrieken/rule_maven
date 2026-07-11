# 2-up PDF support (two rulebook pages per sheet)

Date: 2026-07-10

## Problem

Some rulebook PDFs (spread scans, print-and-play sheets) carry two printed
rulebook pages side by side on each physical PDF sheet. Today the extraction
pipeline renders one image per sheet, so a 2-up book lands as half as many
pages with merged text, wrong reading-order risk across the gutter, and page
numbers that reference sheets instead of printed pages — citations don't match
the physical rulebook.

## Approach

Crop at render/text-extract time using poppler's own crop flags
(`pdftoppm -x/-W`, `pdftotext -x/-W`). No new system dependencies.

Rejected alternatives:

- **Pre-split the PDF with `mutool poster -x 2`** — architecturally cleanest
  (everything downstream sees a normal PDF) but mupdf is not installed; new
  deploy dependency for a niche feature.
- **ImageMagick post-render split** — extra tool in the hot path and does
  nothing for the text layer, so every born-digital 2-up book would pay full
  OCR+vision cost.

## Data model

- `documents.two_up` boolean, default `false`. Set by the admin on the prepare
  page before extraction. Flipping it requires a re-extract (already the admin
  workflow for extraction problems).
- **Manual toggle, no auto-split.** A single landscape A4 page and a 2-up A4
  spread have the identical aspect ratio (√2 ≈ 1.414), so geometry alone
  cannot distinguish them. Instead `two_up_suspect?/1` (first-sheet aspect
  ratio ≥ 1.3 via `pdfinfo`) drives a hint on the prepare page so the admin
  notices before extracting.

## Page identity

With `two_up`, logical page `n` (1-based) maps to physical sheet
`div(n + 1, 2)`; odd `n` is the left half, even `n` the right. Logical indices
exist only *inside* extraction: after pagination the stored page maps are
rewritten to carry the true physical `sheet` plus a `half` field
("left"/"right", a new Page embed field — JSONB, no migration). Every consumer
of `page.sheet` (citations, `SHEET N` markers, review UI, printed-page anchor,
per-page re-extract) therefore sees real sheet numbers with no 2-up awareness;
UI labels append "(left/right)" where a bare sheet number would be ambiguous.
Per-page re-extract renders from the *stored* `half`, never the live `two_up`
flag — flipping the toggle after extraction can't corrupt existing pages.
`assign_printed_from_anchor` assigns two printed numbers per anchored sheet
when halves are present. Printed-page detection *improves*: each logical page
owns its own footer number.

`RuleMaven.Extract.TwoUp` holds the pure mapping + crop-geometry math
(logical→{sheet, half}, pixel/point crop args, pdfinfo size parsing). Sheet
sizes are rotation-corrected: pdfinfo reports the unrotated media box plus a
`rot:` line, while poppler renders after `/Rotate`, so 90°/270° sheets swap
width/height before crop math.

## Pipeline changes (`RuleMaven.RulebookDownloader`)

1. `extract_document` threads `doc.two_up` down to both extraction paths and
   rewrites the paginated pages to physical sheet + half.
2. Vision cross-check path: logical total = 2 × `sheet_count`. Per-sheet sizes
   are read **once** (`sheet_sizes/3`, one `pdfinfo -f 1 -l N` pass) into a
   `{:two_up, sizes}` layout tuple carried in the per-page ctx — no pdfinfo
   spawn per render. Missing sizes fail the extraction fast with a clear error.
3. `pdftext_pages_two_up` (text layer): per sheet, two `pdftotext -f s -l s`
   runs cropped to each half (points; pdftotext default resolution is 72). The
   T0 trusted-layer fast path keeps working for born-digital 2-up books. The
   2-up layer skips `aligned_layers`' trailing-empty trim — a blank final
   right half is structural on odd-page books and must not discard the layer.
4. Legacy OCR path: `render_pages` builds the sizes map once and loops the
   cropped render per half; the trust branch uses the split layer pages and
   sends the whole book to OCR if any page is `column_suspect?` (`-layout`
   reordering protection the cross-check engine gets per page).
5. `reextract_page` takes the physical sheet + a `half:` option (the page's
   stored layout); `ReextractPageWorker` passes `page.half`.

## Error handling

- `pdfinfo` size lookup failure → 2-up extraction errors out up front
  (cross-check) or falls to OCR/plain paths (legacy/suspect probe).
- Sheets of differing sizes are handled: sizes are per sheet, not global.

## UI safeguards

- Toggle shown only for real `.pdf` sources (images/native formats share
  `pdf_path` but have no sheets to split).
- Toggle blocked while an extraction is running (the worker read the flag at
  start; a mid-run flip would leave pages inconsistent with the flag).
- The wide-sheet hint probe runs via `start_async` with a per-doc socket
  cache — never a shell-out in the LiveView process during mount/reload.

## Testing

- Unit tests for `TwoUp` (mapping, crop args, odd geometries).
- One render integration test against an ImageMagick-built 2-up PDF fixture
  (two visibly distinct halves), skipped when `magick` is absent.
- No full-suite run; only touched test files.
