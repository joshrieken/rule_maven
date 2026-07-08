# Table Tools sub-bar + floating tool panel

**Date:** 2026-07-08
**Status:** Design approved, pending spec review
**Area:** `RuleMavenWeb.GameLive.Show` (`lib/rule_maven_web/live/game_live/show.ex`)

## Problem

The game Q&A page (`show.ex`, ~5600 lines) crams every table tool into a
single vertical stack that only renders in the empty state. Two failures:

1. **Overwhelm on first load.** The empty state stacks ~10 cards (game hero,
   Dress-in-colors, Did-you-know, First Player, Turn Wizard, Teach-in-60s,
   Common Mistakes, Setup Checklist, House Rules, Quiz). Ask-the-question —
   the primary action — competes with a wall of secondary tools.
2. **Tools vanish mid-game.** The moment a conversation starts the whole stack
   is gone (only a slim sticky Did-you-know survives). A player mid-session
   can't reach the Turn Wizard or Checklist without clearing the chat.

The header also already overflows into a `⋯` menu, a Rulebooks dropdown, and
several inline pills.

## Goals

- Declutter the empty state to its primary job: **hero + ask box + suggested
  questions**.
- Make every table tool **reachable at any time** (empty *and* mid-conversation)
  from a persistent sub-bar.
- Fold header overflow into the same system.
- **Mobile-first** (hard rule): everything works and looks good at 390px.
- Tools keep their state across open/close (resume where you left off).

## Non-goals

- No change to the *behavior* of individual tools (Turn Wizard logic, Quiz
  scoring, etc.) — this is relocation + a new host, not a rewrite.
- No multiple-simultaneous-expanded floating windows on desktop (v1 keeps a
  single expanded panel; see Future).
- No server-side/account persistence of panel layout (localStorage only).

## Design

### 1. Persistent slim sub-bar

A new single-line row (~32px) directly under the header, **always rendered**
(empty state and mid-conversation):

```
[← Catan  ⚖️2.3]                          [Admin ▾] [☰]   ← header (row 1)
[ 🎲 Play ▾    📚 Learn ▾    💬 More ▾ ]                   ← sub-bar (row 2)
```

Three short group pills fit 390px comfortably. The header sheds its overflow:
the `⋯` menu, Rulebooks dropdown, and Community/Cheat-sheet pills move into the
groups below. Header keeps only: back, title + difficulty, Admin menu (admins
only), and the `☰` question-sidebar toggle.

### 2. Group → tool mapping

Each group `▾` opens a small themed menu (reuse the existing `card-menu`
component). Picking a tool opens it in the shared floating panel (§3). "More"
entries that are pure links (Community, Overview, BGG) navigate as today.

- **🎲 Play** (do it at the table now): Turn Wizard · First Player · Setup Checklist
- **📚 Learn** (teach me): Teach it in 60s · Quiz · Common Mistakes · Did-you-know · House Rules
- **💬 More** (go elsewhere): Community Q&A · Rulebooks · Cheat Sheet · Overview · BGG · 🖌️ Dress in colors

**Why House Rules is under Learn, not Play:** house rules are a *group-shared
artifact*, not a live-play action. A planned future feature — game groups with
their own shared space — will own house rules as a community-layer concept.
Grouping House Rules under Learn now (alongside the other "understand this game"
tools) keeps the taxonomy coherent when groups land, instead of stranding it in
a per-session "Play" bucket.

### 3. Shared floating tool panel — multi-pill dock

All tools flow through one shared panel host for consistency. State machine:

- Assign `@tool_states` — a map `tool → :expanded | :minimized`. A tool absent
  from the map is closed.
- **Invariant: at most one `:expanded`; any number of `:minimized`.**

Transitions:

| Action | Effect |
|--------|--------|
| Open tool X from a group menu | If some Y is `:expanded`, Y → `:minimized` (joins dock, not discarded). X → `:expanded`. |
| Minimize X (`–` on the panel) | X → `:minimized`. |
| Tap a dock pill for X | X → `:expanded`; the currently-expanded tool (if any) → `:minimized`. |
| Close X (`✕` on the panel/pill) | X removed from `@tool_states`. X's own tool-state assigns survive, so re-launching from the menu resumes. |

**Expanded rendering, by pointer type** (gate on `matchMedia('(pointer:coarse)')`,
matching the existing coarse-pointer patterns):

- **Desktop (fine pointer):** a floating draggable card. **No backdrop** — the
  chat stays fully interactive (you can read and ask while it's open). Drag by
  the panel header. Position persisted to `localStorage`.
- **Mobile (coarse pointer, 390px):** a bottom sheet. Chat visible above and
  the ask box remains tappable. No drag.

**Dock** = a horizontal row of peek pills at the bottom edge, above the
composer. Scrolls sideways when several tools are parked. Desktop: pills sit
bottom-right; mobile: pills span the bottom edge. Each pill shows live state
(`🕹️ Turn 2/5`, `🧠 Quiz 3/8`, `✅ Setup 4/9`).

### 4. State persistence — nearly free

Each tool's state already lives in socket assigns for the whole LiveView
session: `quiz_idx` / `quiz_score`, the Turn Wizard step, `checklist_done`,
`fp_pick`, `rule_card`. The change is simply: **close/minimize no longer resets
these — it only toggles visibility via `@tool_states`.** Reopening resumes
exactly where the player left off. No new persistence layer.

The only newly-persisted bit is the **desktop panel position** (x/y in
`localStorage`), handled by the JS hook — mirroring how `ChecklistStore`,
`VoiceDefault`, and `GameThemeHint` already round-trip small bits of UI state.

### 5. Empty state, decluttered

The empty state collapses from ~10 stacked cards to: **game hero (image, stats,
difficulty) + prominent ask box + suggested questions.** Everything else is one
tap away in the sub-bar. The slim sticky "Did you know?" bar may stay (already
conditional and well-liked); it can also be launched as a tool.

### 6. Composer unchanged

The persona picker and expansion toggles stay in the composer — they're
per-ask controls, not table tools, so they do not move to the sub-bar.

## Components / refactor

`show.ex` is already ~5600 lines; do not pile more in. Extract:

- **`RuleMavenWeb.GameLive.SubBar`** — function component rendering the three
  group menus (Play / Learn / More) from the tool registry.
- **`RuleMavenWeb.GameLive.ToolPanel`** — the shared floating-panel host + dock,
  with one `render_tool/1` clause (or per-tool function component) per tool.
  The existing tool markup moves here verbatim; only the outer wrapper (panel
  chrome, minimize/close controls) is new.
- **`FloatingPanel` JS hook** (`assets/js/hooks/`) — branches on
  `(pointer:coarse)` for drag-vs-sheet behavior, persists desktop position,
  wires minimize/expand/close to server events. Follows the shape of the
  existing `ChecklistStore` / `VoiceDefault` hooks.

A small **tool registry** (id, group, emoji, label, `render` reference,
optional live-state summarizer for the pill) drives both the menus and the
panel, so adding a tool is one entry, not edits in three places.

### New / changed server events (`show.ex`)

- `open_tool` (`phx-value-tool`) — set X `:expanded`, demote prior expanded.
- `minimize_tool` (`phx-value-tool`) — set X `:minimized`.
- `close_tool` (`phx-value-tool`) — drop X from `@tool_states`.
- `expand_tool` (`phx-value-tool`) — dock pill tap; expand X, demote prior.
- `panel_position` (from hook) — persist desktop x/y (may be localStorage-only,
  no server round-trip needed; decided during implementation).

Existing tool events (`quiz_answer`, `turn_next`, `toggle_step`,
`shuffle_rule`, `roll_first_player`, …) are unchanged.

## Error / edge handling

- Tools disabled by context (e.g. Settle-an-argument when asks are paused, or
  when `source_count == 0`) render their menu item disabled, same gating as
  today.
- Admin-only tools (Rulebook HTML, Prepare, Edit/Review) stay behind
  `Users.can?(@current_user, :admin)` and live in the Admin menu / More group
  as appropriate.
- If `@tool_states` somehow holds two `:expanded` (bug), render only the first;
  the invariant is enforced on every transition, so this is defensive only.

## Testing

Per the "run only necessary tests" rule — targeted, one representative test per
mechanism, no full suite:

- **State machine:** a LiveView test asserting the invariant — open A, open B →
  A becomes `:minimized`, B `:expanded`; tap A's pill → swap; close A → gone
  from `@tool_states` but re-open resumes its assign state (e.g. quiz score
  preserved).
- **Persistence-across-close:** answer one quiz question, close the panel,
  re-open → score retained.
- **Mobile render:** 390px Puppeteer sweep (per mobile-support recipe) — sub-bar
  single row, sheet + dock reachable, composer still usable with a tool open.
- **Contrast:** any new pill/menu colors clear the WCAG floors enforced by the
  existing contrast tests.

## Rollout / deploy notes

- Pure UI/LiveView change; no migration.
- Update `/help` guide + FAQ and the game-page tour (`RuleMavenWeb.Tours`,
  `data-tour` anchors) to point at the new sub-bar — the tour currently anchors
  `data-tour="turnwizard"`, `"teach"`, `"suggestions"`, `"voices"`, etc., which
  move. Standing rule: user-facing features update help + tours.
- Verify in-browser (major behavior change → browser verification warranted).

## Future (out of scope)

- **Game groups + shared space** — will own House Rules as a community-layer
  concept (drives the Learn grouping above).
- **Multiple simultaneous expanded floating windows** on desktop (true
  multi-window). v1 keeps the single-expanded + dock model.
- **Per-account panel layout** sync (v1 is localStorage / per-browser).
