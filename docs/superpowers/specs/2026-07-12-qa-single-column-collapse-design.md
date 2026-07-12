# Q&A Screen: Collapse the Dead Middle Pane into a Single Q&A Column

## Problem

On desktop the Q&A screen renders three visible columns:

1. **Left sidebar** — the `QUESTIONS` history list (`show.ex:3501`, `#question-sidebar`). Every thread, active one highlighted. This is the navigator.
2. **Middle floating chip** — `.qa-chip` (`show.ex:3705`): the active question text (`@qa_active_question`) plus a `◂ N / M ▸` pager, floating alone in a large gradient void.
3. **Right pane** — the `.answer-pane` scroll region (`show.ex:3731`) showing the question as an orange user-role bubble (the `@conversation` loop at `show.ex:3859`) stacked on top of the answer verdict (LEGAL MOVE / citation / related).

The active question therefore renders **three times** (sidebar row, middle chip, answer-pane bubble). Worse, the middle is a wasted third of the screen: `.qa-chip` (`flex:0 0 auto`) sits left while `.answer-pane` (`flex:1; max-width:48rem; margin:0 auto`) centers within the remaining flex area, leaving a dead gradient gap between them.

Root cause: `show.ex:3488` wraps `#question-sidebar`, `.qa-chip`, and `.answer-pane` as three siblings in **one horizontal flex row**. The `.qa-chip` CSS (`app.css:1072`) and comments still describe it as "Row 1 of a fixed 3-row frame" — a stale intent from before the two-pane refactor (commit 56c667d) turned that row into a column.

The answer-pane already implements the desired layout: question bubble on top of its answer, one pane. The middle chip is pure duplication of that bubble; its only unique value is the sequential pager.

## Goal

One Q&A column: a fixed slim pager bar on top, the scrolling question-bubble-plus-answer below. No dead gradient column, question text shown once (the bubble). Sidebar unchanged. The shipped zero-layout-shift guarantee (answer streaming never moves the pager or composer) is preserved.

## Design

### Layout

```
horizontal flex row (show.ex:3488):
   [ #question-sidebar (16rem) | Q&A column (flex:1, min-width:0) ]

Q&A column — NEW vertical flex wrapper:
   ┌───────────────────────────────┐
   │  ◂    3 / 38    ▸   pager bar  │  flex:0 0 auto, fixed, NO question text
   ├───────────────────────────────┤
   │  🟠 Can trading occur…         │  question bubble (unchanged, already here)
   │  ✅ LEGAL MOVE  answer…        │  scrolls — .answer-pane (flex:1)
   └───────────────────────────────┘
```

- Introduce a vertical flex-column wrapper (`.qa-column`) that is `flex:1; min-width:0; display:flex; flex-direction:column` inside the existing horizontal row. It contains the pager bar and `.answer-pane`.
- `.answer-pane` stays `flex:1; min-height:0; overflow-y:auto` (the one scroll region) and keeps its `max-width:48rem; margin:0 auto` **centered reading column** — long rule answers stay readable; even gradient margins read as intentional, unlike a floating chip.

### Pager bar (replaces `.qa-chip`)

- Keep the pager: `◂`, `{@qa_active_index + 1} / {@qa_total}`, `▸` with the existing `qa_prev` / `qa_next` handlers (`show.ex:1229`, `1242`).
- **Remove the question-text button** (`show.ex:3713-3718`, `.qa-chip__text`) — the bubble below shows the full question.
- Restyle as a slim full-width bar pinned at the column top (`flex:0 0 auto`, full width, centered pager controls). Rename `.qa-chip` → `.qa-pager` (or restyle in place); update the stale "Row 1 / 3-row frame" comment in `app.css` and `show.ex`.
- The bar renders only when `@conversation != [] && @qa_active_question` (same guard as now, `show.ex:3704`).

### Removals

- **`qa_show_question` overlay** (`show.ex:5255-5261`, `.qa-overlay` / `.qa-overlay__sheet`, CSS `app.css:1107-1129`) — the full question is the bubble now; the "show full question" affordance is dead. Remove the markup, the CSS, and the `qa_show_question` / `qa_hide_question` handlers and the `@qa_show_question` assign.
- Dead CSS: `.qa-chip__text` (`app.css:1083`) after the text button goes.

### Untouched

- `#question-sidebar` and its thread list.
- `@qa_active_question`, `@qa_active_index`, `@qa_total`, `assign_qa_nav/1` (`show.ex:736`) — the pager still needs them.
- The `@conversation` bubble/verdict rendering.
- Composer, tool dock, persona picker.

## Mobile

At 390px the sidebar already collapses (`width:min(16rem,85vw)` + existing mobile handling). The Q&A column becomes the full width; the slim pager bar sits on top, bubble + answer below. Verify per the mobile-first hard rule: no horizontal scroll, pager bar does not wrap, zero layout shift while an answer streams.

## Testing

- Existing feature test for the 390px no-shift + pin-to-top behavior (commit 9291cce) must still pass — the pager stays fixed above the scroll region, so streaming still moves nothing.
- Update/extend any test asserting `.qa-chip__text` or the `qa_show_question` overlay (those affordances are removed).
- Confirm `qa_prev` / `qa_next` still walk `@threads` and the `N / M` count is correct.

## Non-goals

- No change to sidebar navigation, search, or the community pool.
- No change to answer rendering, citations, related questions, or personas.
- Not removing the pager (sidebar click-any-item does not give sequential walk or a position count).
