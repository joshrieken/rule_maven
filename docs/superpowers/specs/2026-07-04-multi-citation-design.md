# Multi-citation support

## Problem

Q&A answers cite exactly one page/source (`citation`/`page`/`source` in the LLM's
JSON response schema, mirrored to scalar `cited_passage`/`cited_page`/`cited_source`
columns on `question_logs`). A question spanning multiple rulebook topics (e.g. "how
is the d20 used" — first-player roll, Hero Special Action, Beholder challenge, Wizard
teleport, all on different pages) can only ever get one citation, even after the
retrieval fix (raising default chunk limit 6→10) puts the right chunks in context.
Confirmed live against Horrified: D&D data: the Beholder-mechanic chunk (p.11) ranks
#9 by cosine similarity and, prior to the retrieval fix, was cut before reaching the
LLM; even after the fix, the model still can't cite it because the schema only holds
one page.

## Goal

Let an answer carry a list of citations, one per distinct rulebook passage the model
actually relied on — no artificial cap, no padding to hit a target count.

## Design

### Prompt schema (`RuleMaven.Prompts` `@answer`)

Replace the single `"citation"` / `"page"` / `"source"` fields with:

```
"citations": [
  { "quote": string, "page": integer, "source": string }
]
```

Prompt instructions: emit one entry per distinct passage actually used to compose
the answer; do not duplicate a passage across entries; do not invent entries to
pad the list. Existing CITATION RULES (verbatim quote, page from `[Page N]`
marker, source from header) apply per-entry. On refusal, `citations: []`.

### Parsing (`RuleMaven.LLM.decode_answer/1`)

Parse `map["citations"]` (list of maps) into `[%{quote:, page:, source:}]`,
coercing/validating each entry the same way the old singular fields were
coerced (`coerce_page/1`, `nilable_string/1`). Malformed/non-list input → `[]`.

Backward-compat mirror: `cited_passage`/`cited_page`/`cited_source` are set from
`citations |> List.first()` (or `nil` if empty). These scalar fields keep feeding
everything that already reads them (FAQ badge, admin table, `Trust.has_citation?`,
answer-pool cache row in `llm.ex`) unchanged.

### Storage (`RuleMaven.Games.QuestionLog`)

New migration: `citations:jsonb`, default `[]`, not null. Existing scalar
citation columns are untouched. New column stores the validated list (see below)
as `[%{"quote" => ..., "page" => ..., "source" => ...}]`.

### Validation (`RuleMaven.Games.Citations`)

New `valid_citations/2`: takes the parsed citation list + retrieved source
chunks, runs each entry through the existing per-citation grounding check
(current `valid?/4` logic, unchanged), and returns only the entries that pass.
An entry with a hallucinated page or an unfindable quote is dropped silently —
it does not invalidate the rest of the list or the answer.

`citation_valid` (existing boolean column) becomes `length(valid_citations) > 0`.

If the model returns zero citations for a non-refusal answer (schema violation)
or all citations fail grounding, behavior matches today's "hallucinated single
citation" path: `citation_valid: false`, scalar fields nil, `citations: []`.

### Ask worker (`RuleMaven.Workers.AskWorker`)

After decoding the LLM response: run `Citations.valid_citations/2` over
`result.citations`, persist the surviving list to the new `citations` jsonb
column, and mirror survivors[0] into the existing scalar columns exactly as
today (no behavior change for existing single-citation consumers).

### UI (`RuleMaven_web` `game_live/show.ex` ~line 2249)

Replace the single citation block with `Enum.map(msg.citations || [], fn c ->
citation_block(c) end)` — same visual block (source · p.N header + quoted
passage body) repeated once per citation, stacked vertically. If `citations` is
empty/nil (rows from before the migration, or answers with a scalar citation but
no `citations` list backfilled), fall back to rendering the single block from
the legacy scalar fields, so old conversation history doesn't go citation-less.

### Out of scope

- FAQ page badge (`faq.ex:326`) and admin table (`admin_live/questions.ex:490`)
  keep showing only the primary (first) citation — multi-citation display is a
  Q&A-thread-view enhancement only, not the FAQ/admin surfaces.
- No cap on citation count (model's judgment, per user decision) — no code-level
  enforcement of a max list length.
- No backfill of `citations` for historical rows — they render via the legacy
  scalar-field fallback in the UI.

## Testing

- `Citations` unit tests: `valid_citations/2` with a mix of grounded/ungrounded
  entries — confirms partial-drop behavior and that at least one grounded entry
  yields `citation_valid: true`.
- `LLM.decode_answer/1` unit tests: array parsing, malformed/missing `citations`
  key, empty list, mirror-to-scalar-fields behavior.
- Existing `ask_worker` / `games_retrieval` tests continue to pass unchanged
  (backward-compat scalar fields untouched).
- Manual verification: re-ask the Horrified D&D d20 question, confirm the
  answer now shows multiple citation blocks including the Beholder p.11 passage.
