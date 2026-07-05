# Citation card grouping + sort

## Problem

The multi-citation feature (see `2026-07-04-multi-citation-design.md`) renders one
citation block per entry in `citation_list(msg)` (`lib/rule_maven_web/live/game_live/show.ex`),
in whatever order the LLM returned them. Two problems:

1. If the model cites the same page/source twice (two distinct supporting
   sentences from the same passage), it renders as two separate cards with the
   same `p.N · Source` header, which reads as redundant/cluttered.
2. Cards render in citation order, not page order, so a multi-topic answer
   citing p.11 before p.5 shows the pages out of reading order.

## Goal

Group citations that share the same page AND source into one card (joining
their quotes with an ellipsis), and sort cards by page ascending.

## Design

This is a pure render-time transformation — no schema or persistence change.
It lives entirely inside `citation_list/1` (`lib/rule_maven_web/live/game_live/show.ex:3269`),
which already normalizes a message's citations (new `citations` field, or the
legacy scalar-field fallback) into a list of `%{"quote" =>, "page" =>, "source" =>}`
maps for the template to loop over. This change adds a grouping/sorting pass
after that normalization, before the list reaches the template.

### Grouping key

Group by the exact `{page, source}` pair — both must match. Two citations on
the same page number but from different sources (e.g. "Core rules p.5" and
"FAQ p.5") stay as separate cards; merging them would misattribute a quote to
the wrong document under a shared header.

### Merging quotes within a group

A group with 2+ quotes joins them, in their original relative order, with
`" … "` (a single ellipsis character, not three literal dots) into one string,
rendered as a single blockquote. A group with exactly one quote is unchanged.

True textual contiguity (whether two quotes are actually back-to-back in the
source rulebook) cannot be determined from what's persisted — only the
`quote`/`page`/`source` triple is stored per citation, not the surrounding
rulebook text or character offsets. So every merged (2+ quote) card always
gets the `…` separator; there is no "these happen to be adjacent, skip the
ellipsis" case. This is an accepted simplification: in practice the model
quotes distinct supporting sentences, which are essentially never truly
contiguous, so this is not a visible loss of accuracy.

### Sorting

After grouping, sort by `page` ascending. A group with no page (`page == nil`)
sorts after every group that has a page — it can't be placed numerically, and
appending it is the least surprising placement (it doesn't shove pageless
citations in front of ordered ones).

### Scope

- Render-time only. The persisted `citations` jsonb list keeps the model's
  original per-citation entries, ungrouped — grouping is a presentation
  concern recomputed on every render, not baked into storage. This means a
  future change to grouping rules just changes rendering, no backfill needed.
- Only the Q&A thread's citation cards (`citation_list/1`'s consumer in
  `show.ex`) are affected. FAQ badge and admin table already only show the
  first/primary citation (out of scope per the multi-citation design) and are
  untouched here.
- No change to `Citations.valid_citations/2`, `AskWorker`, or any persisted
  field — this is presentation logic layered on top of the already-validated,
  already-persisted list.

## Testing

No existing automated test coverage targets `citation_list/1`'s internals
directly (it's a private LiveView render helper) — verification is manual:
render a message with 3+ citations spanning 2 pages, including a same-page
duplicate pair, and confirm (1) the duplicate pair merges into one card with
an ellipsis-joined quote, (2) cards appear in ascending page order, (3) a
citation with no page renders last.
