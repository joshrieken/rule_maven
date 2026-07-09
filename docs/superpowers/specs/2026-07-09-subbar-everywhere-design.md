# Sub-bar everywhere + persistent tool windows

**Date:** 2026-07-09
**Status:** Approved

## Goal

The game sub-bar (🎲 Play · 📚 Learn · 💬 More) is visible and fully functional on
every user-facing game screen, tool windows survive navigation (thread switches
AND page-to-page), and on desktop the minimized-tool bar sits in normal document
flow above the composer instead of overlaying the main area.

## Scope

User-facing game screens:

- `/games/:id` (GameLive.Show) — already has the sub-bar and tool machinery.
- `/games/:id/community` (+ `/faq` alias, GameLive.Community) — currently only
  "← Back / Admin Review →" links at top; gains the sub-bar and working tools.
- Cheat sheet (`/games/:id/cheatsheet`) — standalone static HTML page in a new
  tab, own chrome. **Out of scope.**

## Components

### 1. `RuleMavenWeb.GameLive.ToolHost` (new)

Extracted from Show so Community can share it:

- `mount_tools(socket, game, user)` — moves tool-data loaders out of Show
  (`load_quiz`, `load_setup`, `load_turn_flow`, `load_score_categories`,
  `load_teach_pitch`, `load_common_mistakes`, `load_first_player`, dyk facts,
  own + community house rules) and seeds `tool_states` / `tool_order` /
  `single_panel?`. Hydrates volatile tool state from `TableSession` (below).
- `handle_tool_event(event, params, socket)` — moves tool event clauses:
  open/expand/minimize/close/focus_tool, quiz_*, turn_*, toggle_step /
  reset_checklist / checklist_restore, shuffle_rule, roll_first_player,
  house-rule CRUD + recheck/block/visibility, score-pad events.
  Every state-mutating handler writes through to `TableSession`.
- `events()` — the list of event names; Show and Community each add one
  delegating `handle_event` clause guarded by `event in ToolHost.events()`.
- Show keeps ask/thread/vote/report/etc. events untouched.

### 2. `RuleMaven.TableSession` (new)

Server-side write-through session store for "at the table" tool state:

- ETS table (public, owned by a supervised holder process), keyed
  `{user_id, game_id}`.
- Snapshot map: `tool_states`, `tool_order`, plus per-tool volatile assigns
  enumerated in one `ToolHost.session_keys()` list (quiz idx/choice/score,
  turn phase/open, score pad entries, fp_pick, house-rule form toggles as
  appropriate).
- Hydrated at mount by `mount_tools`; written on every tool event.
- TTL sweep (~12h) so stale sessions don't accumulate.
- Per-instance memory; reset on deploy/restart is acceptable (ephemeral table
  session, not durable data). Panel geometry stays in localStorage (existing,
  client-only). Checklist keeps its existing localStorage restore.

### 3. Community page changes

- Mount: stash `coarse_pointer` connect param once at mount (connect params are
  mount-only), call `ToolHost.mount_tools/3`.
- Header: replace the "← Back / Admin Review →" row with `← Back` link +
  sub-bar. The More menu already carries admin Edit/Review/Prepare, so the
  top-right Admin Review link is removed.
- Render `<ToolPanel.tool_panel {assigns} />` at the page root (no
  `.chat-layout` stacking-context trap here).

### 4. SubBar tweak

New attr `on_game_page` (default `true`). More→Overview renders
`patch` on Show (preserves LiveView state) and `navigate` elsewhere
(cross-LiveView patch crashes).

### 5. Desktop minimized tray in flow

- Minimized-pill bar becomes a normal flex row above the composer inside the
  chat column — main area is vertically scrunched and scrolls as usual; the
  bar no longer overlays content.
- Expanded floating windows and the mobile bottom sheet are unchanged.
- Drop `--rm-tray-bottom` coupling where the in-flow bar makes it obsolete.

## Error handling

- TableSession lookups return an empty snapshot on miss — mount never fails on
  absent/expired sessions.
- Restored tool ids are validated against `ToolRegistry` (a tool removed in a
  deploy mustn't crash hydration).
- Restored per-tool state is merged shallowly over freshly-loaded defaults, so
  stale keys can't shadow required assigns.

## Testing

- TableSession unit test (write-through, hydrate, TTL sweep, miss → empty).
- Community live test: sub-bar renders; `open_tool` opens a panel.
- Restore-after-navigate live test: open tool on Show → navigate to Community
  → window still open (and volatile state intact).
- Existing Show tool tests pin no regression.
- 390px mobile check (sheet mode via `coarse_pointer`).

## Known limits

- Session state is per-server-instance memory; lost on restart/deploy.
- Cross-device continuity out of scope.
