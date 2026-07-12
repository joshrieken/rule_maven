# Two-pane Q&A — zero layout shift

**Date:** 2026-07-12
**Status:** Design, pending review
**Area:** `lib/rule_maven_web/live/game_live/show.ex` + `assets/js/app.js` + `assets/css/app.css`

## Problem

Today the Q&A screen is a single appended chat list (`#chat-messages`, `show.ex:3602`).
As an answer arrives the viewport moves for several independent reasons:

1. The `ChatScroll` hook (`app.js:169`) auto-scrolls each new answer into view
   (`scrollIntoView`, `scroll_bottom`, `scroll_top` pushes from `show.ex:371,513,1656`).
2. A short "Thinking…" placeholder is swapped for a tall answer → content below jumps.
3. The answer streams token-by-token, growing the list, creeping the viewport.
4. Trailing UI (followup chips `show.ex:4073`, "also asked" `:4096`, "Ask exactly this"
   `:4023`, suggested questions `:3702`) renders *after* the answer and shoves layout.

Goal: **the screen never moves when an answer appears, in any scenario** — streaming,
placeholder swap, trailing chips, persona restyle, error/refusal.

## Core idea

Stop treating Q&A as a chat transcript. Split into a **fixed outer frame** with **one
scroll region**: the answer. Because the answer lives in its own fixed-height scroll box,
it can grow to any length without moving the question chip, the composer, or the page.

This is layout **C · Answer-primary** from brainstorming (chosen over master-detail and
stacked-split as the best mobile-first fit).

## Layout

Mobile-first, single column, three fixed rows in a flex/grid column that fills the
available height (the existing `.chat-layout` container, `app.css:1037`):

```
┌───────────────────────────────┐
│ Question chip  ◂ …?   3/8 ▸    │  fixed, never scrolls
├───────────────────────────────┤
│                               │
│   Answer                      │  the ONLY scroll region
│   (streams here, pinned top)  │  overflow-y:auto; flex:1; min-height:0
│   … followup + suggested      │
│     chips live at the bottom  │
│                               │
├───────────────────────────────┤
│ [ composer input ]     [Ask]  │  fixed, never scrolls
└───────────────────────────────┘
```

Desktop is the same frame widened; an optional thread-history list may appear as a side
column later (progressive enhancement, out of scope here).

### Row 1 — question chip (fixed)

- One line, truncated question text + pager `N / M` + prev/next arrows.
- **Tap chip → overlay** (sheet/popover) with the full question text, rendered *over* the
  answer. Answer stays put underneath. Dismiss to close. Never an inline expand (inline
  push would move the answer — the thing we are eliminating).
- Pager arrows step through **the current thread's Q&As only** (reuse existing thread /
  conversation model). Cross-thread history stays in the separate thread list, unchanged.
- Switching Q&A via the pager **replaces** the answer pane's content — it does not append.

### Row 2 — answer pane (the one scroll region)

- `overflow-y:auto`, `flex:1`, `min-height:0` so it, and only it, scrolls.
- **Pin-to-top, no follow.** On a new/switched answer the pane resets `scrollTop = 0` and
  stays there while text streams in below the fold. No auto-follow of the stream. The user
  scrolls down themselves. This is the strict no-movement behavior and replaces the current
  auto-scroll entirely.
- **Reserved height, not reserved slots.** The pane is a fixed-height box from mount. The
  streaming/thinking/placeholder states (`row_placeholder?` `:3761`, `thinking?` `:3894`,
  `.cite-pending` `:3917`, `VoiceLoader` `:3933`) render *inside* the box. Swapping
  placeholder → answer → restyled answer changes only the box's inner content, which is
  below the fold and clipped by the box — the frame does not move.
- **Trailing chips at the bottom of the scroll content** (layout choice A): followups,
  "also asked", suggested questions, and "Ask exactly this" all render as the tail of the
  answer content. Because they are inside the pinned-to-top fixed box, they appear below the
  fold; reaching them is a scroll, never a shift. No pre-reserved slot needed (drops the
  `show.ex:4011` reserved-slot mechanism's shift purpose, though the disabled-while-streaming
  gate stays).

### Row 3 — composer (fixed)

- Pinned at the bottom of the frame, outside the scroll region. Never moves regardless of
  answer length or streaming state. (Today it rides `qa-rise-in` / can be pushed; it becomes
  a fixed frame row.)

## What changes in code

- **`show.ex` template (`render/1`, from ~3323):** restructure the `#chat-messages` list
  into the three-row frame. The message loop (`:3729`) is replaced by rendering exactly one
  active Q&A: the chip (row 1), the current answer + its trailing chips (row 2), composer
  (row 3). The list-of-bubbles markup (`.chat-msg*`) is retired.
- **Pager state:** an assign for the active index within the current thread's Q&A list.
  Prev/next are `phx-click` events that set the active Q&A and reset the pane scroll.
- **Streaming:** stream text still lands in row 2's content; the only behavioral change is
  no auto-scroll — the pane stays pinned to top.
- **`app.js`:** replace `ChatScroll` (`:169`) with a small hook that, on new/switched
  answer, sets the answer pane `scrollTop = 0` (pin-to-top) and does nothing else — no
  `scrollIntoView`, no follow. Remove the `scroll_bottom` / `scroll_top` / `scrollToLatest`
  pushes tied to answer arrival (`show.ex:371,513,1656`); thread-switch scroll becomes
  "reset answer pane to top."
- **`app.css`:** `.chat-layout` becomes the fixed three-row column
  (`display:flex; flex-direction:column; height:<viewport>`); add the answer-pane scroll
  class (`flex:1; min-height:0; overflow-y:auto`); the question-overlay sheet; drop the
  per-message `msg-in-*` / `answer-rise` animations that assume the append model (keep a
  subtle in-place fade if wanted, but nothing that changes box height).
- **Question overlay:** new small component + toggle assign; renders over the answer pane.

## Error / refusal / persona states

All render *inside* row 2, so they inherit no-shift for free:

- Error ⚠️ answers, refusals, and the retry path show in the answer box.
- "Ask exactly this" (refusal/misread recovery) sits in the trailing chips at the bottom of
  the box — still reachable, still below the fold, no shift.
- Persona restyle (`VoiceLoader`, `voice-loader` `app.css:4302`) swaps the box's content in
  place; the box height is fixed, so no movement.

## Non-goals

- Desktop side-by-side history list (later progressive enhancement).
- Changing the ask pipeline, threads model, streaming transport, or any server-side ask
  logic. This is a presentation-layer restructure only.
- Flattening the thread/conversation model.

## Testing

- LiveViewTest: asking a question renders one active Q&A in the frame (chip + answer +
  composer), not an appended list; pager prev/next swaps the active answer.
- Feature/Playwright at **390px** (mobile-first hard rule): ask a question, assert the
  composer's bounding box `top` is unchanged between "thinking", "streaming", and
  "answer complete" states (this is the concrete no-shift assertion); assert the answer pane
  is scrolled to top on a fresh answer; assert trailing chips are inside the scroll region.
- Overlay: tapping the chip opens the full-question sheet without changing the answer pane's
  scroll position or the frame layout.
- Keep zero-warnings / run-only-necessary-tests rules.

## Open risks

- Fixed-height frame needs a correct height source on mobile (dynamic viewport units /
  `100dvh`) so the composer isn't hidden behind the browser chrome or the on-screen keyboard.
  Verify with the keyboard open at 390px.
- The thread/conversation → "current thread's Q&A list" mapping for the pager must be exact
  (`show.ex` already has thread-switch handlers at `:371`); reuse, don't reinvent.
