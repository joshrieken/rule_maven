# Tool tray + resizable panels — design

**Date:** 2026-07-08
**Area:** Game Q&A floating tool panels (`GameLive.ToolPanel`, `Hooks.FloatingPanel`)

## Problem

Two complaints about the table-tools floating panel shipped in
`2026-07-08-table-tools-subbar.md`:

1. **Minimized pills land in a weird place.** `.tool-dock` is anchored
   `position:fixed; right:1rem; bottom:5rem` — the *exact same anchor* as
   `.tool-panel`. An expanded panel therefore covers its own dock. On phones the
   dock stretches `left:.5rem/right:.5rem; bottom:4.5rem`, floating over the
   chat composer area with nothing tying it to the layout.
2. **Panels are a fixed size.** `width: min(30rem, calc(100vw - 2rem))`,
   `max-height:70vh`, no user control, nothing remembered. Content-heavy tools
   (score pad, checklist, house rules) want a taller panel; the timer wants a
   short one.

## Goals

- Minimized tools live somewhere predictable, never occluded by the expanded
  panel, and visible while the user keeps chatting.
- Panels are resizable on desktop, and the size survives reload, per tool.
- Mobile sheet gets deliberate height control (snap points), not free resize.
- Works at every width; verified at 390px (mobile-first hard rule).

## Non-goals

- No multiple simultaneously-expanded panels. The `@tool_states` machine keeps
  exactly one `:expanded`; this design does not touch it.
- No server-side persistence of position/size. localStorage only, as today.
- No new LiveView events.

## Design

### 1. Tray (replaces the corner dock)

The dock becomes a **bottom taskbar** — the learned idiom for "minimized but
still running, one click away".

- `.tool-dock` → `position:fixed; left:0; right:0; bottom:var(--rm-tray-bottom)`.
  Pills are left-aligned inside the same gutter as the chat column and the strip
  scrolls horizontally (`overflow-x:auto`) when tools outnumber the width.
- `--rm-tray-bottom` is written by JS from the measured height of `.chat-input`
  (the composer). Fallback `5rem` — today's hardcoded value. On pages with no
  composer (the game overview / empty state) it falls back to `1rem`.
- A `ResizeObserver` on the tray writes `--rm-tray-h`. `.tool-panel` then uses
  `bottom: calc(var(--rm-tray-bottom) + var(--rm-tray-h) + 0.5rem)`, so an
  expanded panel can never sit on top of the pills. With an empty tray
  `--rm-tray-h` is `0` and the panel returns to its current resting place.
- Pills: hover/focus lift, `title="Restore"`, plus a small ✕ (visible on
  hover/focus, fine pointers only) that fires the existing `close_tool` event so
  a tool can be dismissed without restoring it first. On coarse pointers the ✕ is
  hidden — closing happens from the panel — and the strip stays scrollable.
- Small screens: full-width strip, pill height capped at 2.25rem so the tray
  consumes exactly one line above the composer.

The tray is `z-index:55`, below the panel's `60`, so a dragged panel passes over
it rather than under.

### 2. Resize + persistence

Desktop (fine pointer):

- `.tool-panel { resize: both; overflow:auto; min-width:18rem; min-height:8rem;
  max-width:calc(100vw - 2rem); max-height:80vh }` — the native corner grip. Free,
  keyboard/AT-friendly, no custom pointer math.
- `FloatingPanel` persists `{w,h}` to `rm:toolsize:<tool>` when a resize settles,
  next to the existing `rm:toolpos:<tool>`.
- `applySaved()` restores position *and* size, **clamped to the current
  viewport**: a panel sized on a 2560px monitor must not restore off-screen or
  wider than the window on a laptop. Clamp width to `innerWidth - 2rem`, height to
  `80vh`, and pull `left`/`top` back so at least the title bar is reachable.

Mobile (coarse pointer):

- `resize:none`. The sheet gets three snap heights — peek `35vh`, half `55vh`,
  tall `85vh` — expressed as `.tool-panel--snap-0/1/2`.
- Tapping the drag handle cycles snap points; a vertical drag on the handle snaps
  to the nearest. Snap index persists to `rm:toolsnap:<tool>`.
- Free-dragging a sheet to an arbitrary height is fiddly at 390px, hence snaps.

### 3. Components

| File | Change |
|---|---|
| `lib/rule_maven_web/live/game_live/tool_panel.ex` | Dock markup: gutter wrapper, per-pill ✕ (`close_tool`). No new events. |
| `priv/static/assets/js/app.js` | `FloatingPanel`: size persist/restore, viewport clamp, sheet snap. New `Hooks.ToolTray`: owns `--rm-tray-bottom` / `--rm-tray-h`. |
| `priv/static/assets/css/app.css` | Tray restyle, `resize` rules, snap-height classes, panel `bottom` calc. |

Layout measurement lives in `ToolTray`, not `FloatingPanel`: the tray exists
independently of whether a panel is open, and the panel should read a CSS var
rather than re-measure the composer.

## Testing

- `test/rule_maven_web/live/game_live_tool_panel_test.exs`: tray renders one pill
  per minimized tool; pill carries `phx-click="expand_tool"`; ✕ carries
  `phx-click="close_tool"`; no tray element when nothing is minimized.
- Drag, resize, and snap are browser behavior — verified manually at 390px and at
  desktop width, per the mobile-first rule. No JS test harness exists in this
  repo.

## Risks

- **Composer height changes** (textarea grows as the user types). `ResizeObserver`
  on `.chat-input` keeps `--rm-tray-bottom` live rather than measuring once.
- **`resize: both` and `overflow:auto` interact with the sticky title bar.** The
  bar is `position:sticky; top:0` inside the scroll container; that keeps working,
  but the grip sits over the body's bottom-right corner and can land on tool
  content. Padding-bottom on `.tool-panel__body` reserves room.
- **Stale localStorage** from the pre-resize build stores only `{x,y}`. The
  restore path must tolerate a missing `w`/`h`.
