# Persona Picker Modal — Design

## Context

The persona ("Answer persona") picker on the game Q&A page is a `<details class="card-menu">`
dropdown. On mobile the composer instance sits at the right edge (`margin-left:auto`) and its
left-anchored ~280px popup runs ~130px off the right of a 390px viewport (measured: right edge
523 vs 390). Rather than patch positioning, we convert the picker to a **centered modal on all
viewports** and use the extra room to make persona selection a first-class experience: each
persona shows its description and a sample line, a 🔥 badge marks the popular ones, a search box
filters, and a recently-used strip sits on top.

Two pickers exist and both open the **same shared modal**:
- **Composer** picker — sets the user's default voice (`set_default_voice`).
- **Per-answer switcher** on each answer card — re-voices that answer (`set_voice`).

Persona metadata (`label`, `emoji`, `description`, `loading_phrases`) already exists on both
built-in voices (`RuleMaven.Voices.all` + `loading_phrases/2` global fallback) and generated game
voices (`RuleMaven.Voices.GameVoice`). Persona **selection is not tracked anywhere today**, so
popularity + recently-used require a new events table; both start empty and fill after ship.

## Goals

- Persona modal never overflows the viewport (mobile or desktop).
- One shared modal component serves both pickers.
- Richer selection UI: descriptions, voice sample line, 🔥 Popular badge, search filter,
  recently-used strip.

## Non-goals

- Exposing raw usage numbers (badge only, no counts).
- Changing the underlying voice/restyle pipeline or the `set_voice` / `set_default_voice`
  contracts (selection routing is unchanged; we only add event recording + swap the trigger UI).

## Architecture

### Trigger

Each persona pill becomes a plain button (keep current pill styling) with
`phx-click="open_persona_modal"` carrying which picker opened it:
- Composer: `phx-value-target="default"`.
- Per-answer: `phx-value-target="answer"` + `phx-value-msg-id={msg[:id]}`.

A single assign holds modal state:

```elixir
# nil when closed; otherwise the routing context
persona_modal: nil | %{target: :default | {:answer, msg_id}}
```

`open_persona_modal` sets it; `close_persona_modal` clears it; selecting a persona clears it
after dispatching to the existing selection logic.

### Modal component

`persona_modal/1` function component in `show.ex` (co-located with `voice_menu`, which it
replaces). Structure:

- Fixed full-viewport backdrop (`position:fixed; inset:0; z-index`) — click closes.
- Centered panel: mobile ≤640px near-full-width sheet (`inset` margins, max-height ~85vh,
  internal scroll); desktop centered dialog ~420px.
- Header: title ("Answer persona") + ✕ close.
- **Search input** (client-filtered — see below).
- **Recently used** strip (chips) when the user has recent picks for this game.
- Grouped cards, reusing the existing split in `voice_menu`: **Plain**, **✦ {game name}**
  (game voices, `id` prefixed `g:`), **Alternatives** (remaining built-ins).
- Each **persona card** (`persona_card/1`, replaces `voice_menu_item`):
  - emoji · label · ✦ marker for game personas · ★ if it's the user's default ·
    "speaking" state styling for the per-answer target's current voice.
  - `description` line.
  - muted italic **sample** = first entry of `Voices.loading_phrases(voice, game)`; omitted if
    the list is empty. (Built-ins may fall back to generic global phrases — acceptable; their
    description carries the flavor.)
  - **🔥 Popular** badge when the voice is in the game's top-N by selection count.
  - Selected card gets the current accent treatment.
  - `phx-click` = the target's event (`set_default_voice` or `set_voice` with `msg_id`), same
    `phx-value-voice` payload as today.

Reuses existing modal groundwork: body scroll-lock and the `.main-content`
`animation-fill-mode: backwards` fix (so a `position:fixed` panel anchors to the viewport, not a
transformed ancestor — see the reader-modal notes).

### Selection tracking — `persona_events`

New table + schema `RuleMaven.Voices.PersonaEvent`:

| column      | type      | notes                                  |
|-------------|-----------|----------------------------------------|
| id          | bigint    | pk                                     |
| user_id     | bigint    | fk users (nullable for logged-out)     |
| game_id     | bigint    | fk games                               |
| voice_id    | string    | e.g. "neutral", "g:court-jester"       |
| inserted_at | utc       |                                        |

Indexes: `(game_id, voice_id)` for popularity, `(user_id, inserted_at)` for recency.

Recorded inside the existing `set_voice` and `set_default_voice` handlers (fire-and-forget insert;
must not block selection — wrap so a failure is swallowed/logged, never surfaced).

Context module `RuleMaven.Voices` gains:
- `popular_voice_ids(game_id, limit \\ 3)` → `MapSet` of the top voice_ids by count for that game
  (empty when no data → no badges, which is correct).
- `recent_voice_ids(user_id, game_id, limit \\ 4)` → ordered distinct recent voice_ids for the
  user (game-scoped; empty for logged-out or no history → strip hidden).

These are computed when the modal opens (in `open_persona_modal`) and passed as assigns, so the
queries run once per open, not per render.

### Search filter (client-side)

A `PersonaFilter` JS hook on the modal: `keyup` on the search input hides/shows `.persona-card`
rows whose `data-search` (lowercased label + description) doesn't contain the query, and
hides a group heading when all its cards are filtered out. The input carries `phx-update="ignore"`
so LiveView re-renders don't clear it. Purely presentational — no server round-trip, no effect on
selection.

## Data flow

1. User taps a persona pill → `open_persona_modal` → assign `persona_modal` + precomputed
   `popular_voice_ids` / `recent_voice_ids` → modal renders.
2. User types in search → hook filters DOM rows locally.
3. User taps a persona card → existing `set_default_voice`/`set_voice` runs (applies the voice as
   today) → a `persona_events` row is inserted → `persona_modal` cleared → modal closes.
4. Backdrop/✕/Esc → `close_persona_modal` → assign cleared.

## Error handling

- Event insert is best-effort: failure is logged, never blocks or errors the selection.
- Empty popularity/recency data → no badges / hidden strip (graceful, expected at launch).
- Logged-out users: no recently-used (no user_id); popularity still works (counts anonymous
  picks with null user_id).

## Testing

- **Unit** (`RuleMaven.Voices`): `popular_voice_ids/2` ranks by count and respects limit;
  `recent_voice_ids/3` returns distinct, recency-ordered, game-scoped ids; empty inputs return
  empty.
- **LiveView** (`show.ex`): opening the modal from the composer pill and from a per-answer pill
  sets the right `persona_modal.target`; clicking a card dispatches the correct event, inserts a
  `persona_events` row, and closes the modal.
- **Browser** (390px + desktop, puppeteer + auto-login): modal centered with no horizontal
  overflow at either size; search filters cards; recently-used strip appears after a pick.

## Rollout / deploy notes

- Migration for `persona_events`.
- Popularity + recently-used are empty until picks accrue — no backfill (no historical voice data
  exists).
- Supersedes the interim right-anchor dropdown fix (discarded).
- Update `/help` + tours only if a tour step targets the old dropdown (it does not today).
