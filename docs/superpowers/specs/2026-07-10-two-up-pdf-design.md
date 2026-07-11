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
`div(n + 1, 2)`; odd `n` is the left half, even `n` the right. `Games.paginate`
already numbers pages by position in the `\f`-joined text, so `page.sheet`
becomes the logical page number — printed-page detection, citations, HTML,
chunking, and cleanup are untouched (and printed detection *improves*: each
logical page owns its own footer number).

`RuleMaven.Extract.TwoUp` holds the pure mapping + crop-geometry math
(logical→{sheet, half}, pixel/point crop args) so it is unit-testable.

## Pipeline changes (`RuleMaven.RulebookDownloader`)

1. `extract_document` threads `doc.two_up` down to both extraction paths.
2. Vision cross-check path: logical total = 2 × `sheet_count`;
   `render_one_page` renders the owning sheet with a half-width crop
   (`pdfinfo -f s -l s` page width in points → pixels at the render dpi).
3. `pdftext_pages` (text layer): per sheet, two `pdftotext -f s -l s` runs
   cropped to each half (points; pdftotext default resolution is 72). The T0
   trusted-layer fast path keeps working for born-digital 2-up books.
4. Legacy OCR path: `render_pages` loops the cropped `render_one_page` per
   half; the legacy whole-`pdftotext` trust branch uses the split layer pages.
5. `reextract_page` accepts the logical index + `two_up:` option and derives
   sheet/half; `ReextractPageWorker` passes `doc.two_up`.

## Error handling

- `pdfinfo` width lookup failure → render error for that page; existing
  per-page error handling (flag for review, keep layer text) applies.
- Sheets of differing sizes are handled: width is read per sheet, not once.

## Testing

- Unit tests for `TwoUp` (mapping, crop args, odd geometries).
- One render integration test against an ImageMagick-built 2-up PDF fixture
  (two visibly distinct halves), skipped when `magick` is absent.
- No full-suite run; only touched test files.
