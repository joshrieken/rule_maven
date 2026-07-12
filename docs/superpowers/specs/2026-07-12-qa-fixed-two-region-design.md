# Q&A Screen: Fixed Question-Top / Answer-Bottom Two-Region View

## Problem

The Q&A screen still renders as a chat/transcript: the active question is an orange, right-aligned `.chat-msg-user` bubble stacked on top of a left-aligned assistant answer inside the single `.answer-pane` scroll region. But the product is **not** a conversation — the data model is 1 thread = 1 question = 1 answer (no in-thread followups). The chat framing is misleading.

Worse, it interrupts reading. After you submit, normalization rewrites the question text (`normalization_changed?/2`, `show.ex:804`), and the verdict/persona row and related-question chips pop in. Because the question bubble and the answer live in the same in-flow scroll region, any of these size changes shove the answer up or down while the user is trying to read it stream in.

## Goal

A fixed two-region view: the **question pinned on top at a height that never changes**, the **answer in its own scroll region below**. Nothing above the answer — not a normalization rewrite, not a pop-in — may move it. The user reads the answer stream in from the top, uninterrupted. Drop the chat-bubble styling entirely.

## Design

### Layout

```
.chat-layout (fixed frame — unchanged)
  sub-bar (unchanged)
  horizontal row:  [ #question-sidebar | .qa-column ]
    .qa-column (vertical flex, flex:1):
      ┌ .qa-question  (flex:0 0 auto, FIXED reserved height ~2 lines) ┐
      │  ◂   {question text, 2-line clamp, ellipsized}   N / M   ▸    │
      └──────────────────────────────────────────────────────────────┘
      ┌ .answer-pane  (flex:1, overflow-y:auto, pinned top, no follow) ┐
      │  ✅ LEGAL MOVE   [persona ▾]   ← reserved slot, no shift        │
      │  Yes — after moving the robber…  (answer markdown)             │
      │  📖 CORE RULEBOOK p.11         (citation card)                 │
      │  Related: [chip][chip][chip]                                   │
      │  ▸ Previous attempts          (collapsible history)           │
      └──────────────────────────────────────────────────────────────┘
  composer (.chat-input — fixed, full width, unchanged)
```

### Top region: `.qa-question` (rename/rebuild from `.qa-chip`)

- `flex: 0 0 auto` with a **fixed reserved height of exactly 2 lines** of the question font (set both `min-height` and `max-height` to the 2-line value; `overflow: hidden`). This fixed height is the mechanism that guarantees the answer region never moves: swapping the raw question for its normalized rewrite changes the text inside the box, never the box's height.
- Contains: prev pager button (`◂`, `qa_prev`), the question text (`@qa_active_question`, 2-line clamp via `-webkit-line-clamp: 2` + ellipsis, tappable), the `{@qa_active_index + 1} / {@qa_total}` count, next pager button (`▸`, `qa_next`). Guarded by `@conversation != [] && @qa_active_question` (unchanged guard).
- The question text is now the prominent element (not a truncated one-line chip) — sized as a readable title, left-aligned, 2-line clamp.

### Long-question expand (tap-to-expand overlay, no reflow)

- Re-introduce a `qa_show_question` / `qa_hide_question` handler pair and a `@qa_show_question` assign (these were removed in the prior single-column collapse; re-add them, purpose-built).
- Tapping the question text opens `.qa-overlay`: an **absolutely-positioned** sheet showing the full `@qa_active_question`, layered OVER the top of the answer region. It must NOT reflow the answer — position it against the fixed `.chat-layout` (a stable containing block; `position:absolute; inset` resolved against a non-scrolling ancestor, not inside `.answer-pane`), so expanding never moves the answer. Backdrop click (`qa_hide_question`) closes it; the sheet's own click is a no-op (`ignore`) to avoid falling through.
- This is the correct, non-duplicative use of an overlay: the question renders in exactly one place (the top region), and the overlay is only its expanded form.

### Answer region: `.answer-pane` de-chatted

- **Remove the `.chat-msg-user` (question) rendering** from the `@conversation` loop — the question lives only in the top region now. No more orange right-aligned bubble.
- **De-chat the assistant message:** remove the flex `align-items: flex-end/flex-start` chat alignment and the bubble framing. Wrap the answer in a **subtle surface card** (`background: var(--bg-surface)`, `border: 1px solid var(--border)`, rounded, padded) that groups verdict + answer + citation + related — reads as a rules answer, not a chat message.
- Keep, in order inside the card / pane: the verdict stamp + persona-switcher row (the existing reserved-slot `row_placeholder?` skeleton that prevents pop-in shift — retained), the answer markdown, the citation card, the related-question chips (append below — they never move the answer's top), and the collapsible "Previous attempts" history (`msg[:history]`).
- Keep the `AnswerPane` JS hook behavior: pin to `scrollTop = 0` only when `data-answer-key` changes, never follow the stream.

### Empty state

Unchanged. When `@conversation == []`, the top `.qa-question` region does not render (its guard is false) and `.answer-pane` shows the existing game intro + suggested questions.

## The no-movement guarantee (why this works)

Three independent facts combine so the answer never moves while reading:
1. `.qa-question` has a **fixed** height → question text rewrite (normalization) changes nothing about the layout below it.
2. `.answer-pane` is a **separate `flex:1` scroll region** anchored between the fixed top region and the fixed composer → its box geometry is constant.
3. Within the pane, the verdict/persona row is a **reserved slot** and related/citation **append below** the answer → nothing inserts above the answer text after it starts rendering. The `AnswerPane` hook keeps it pinned to the top and does not follow the stream.

## Testing

- Extend `test/rule_maven_web/live/game_live/qa_no_shift_test.exs`:
  - The question renders in `.qa-question` (with `.qa-chip__pager` / renamed pager class) and NOT as `.chat-msg-user` inside `.answer-pane`.
  - Assert `refute has_element?(view, ".answer-pane .chat-msg-user")`.
  - Simulate a normalization rewrite (assign a longer `@qa_active_question`) and assert the `.qa-question` element is still present with a fixed-height class (structural proof the box is height-locked; visual height is covered by the feature test).
  - Tapping the question opens `.qa-overlay`; closing removes it.
- Extend `test/rule_maven_web/feature/qa_no_shift_test.exs` (Playwright, 390px): the existing composer-no-shift + answer-pin-to-top assertions must still pass, and add: the `.answer-pane` bounding-top is unchanged before vs. after the question text changes (normalization), and unchanged when the expand overlay opens.

## Mobile

390px: `.qa-question` keeps its fixed 2-line height, the pager does not wrap, the answer region fills the rest and scrolls. Verify per the mobile-first hard rule.

## Non-goals

- No change to the ask/normalization pipeline, the sidebar, the composer, personas, citation content, or related-question generation.
- No in-thread followups / no return to a transcript.
- Not restyling the answer's internal markdown beyond the card wrapper + de-chat.
