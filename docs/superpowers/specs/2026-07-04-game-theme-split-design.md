# Game Theme Split — Design

Date: 2026-07-04
Status: awaiting user review

## Problem

Game Light / Game Dark live in the same header dropdown as the static themes.
That conflates two different preferences:

1. **Static theme** — the user's chosen look everywhere.
2. **Game-match preference** — "when I'm on a page that has a per-game palette
   (Q&A, FAQ), use the game's light/dark theme instead."

Desired behavior: selecting a static theme (anywhere) is just your theme. But
if you've opted into Game Light/Dark, game pages switch to it — even if you
picked a new static theme elsewhere in the meantime. Today, picking any static
theme sets `themeGameMatch = '0'`, wiping the game preference. That's the core
mismatch.

## Scope

Only the Q&A (`GameLive.Show`) and FAQ (`GameLive.Faq`) pages render the
per-game palette (`GameTheme.style_block/1` injects `#game-theme`). No other
pages participate; no new pages are added by this change.

## Design

Two independent localStorage preferences:

| Key | Values | Written by |
|---|---|---|
| `theme` | static theme slug | main theme dropdown only |
| `themeGameMatch` | `game-light`, `game-dark`, or cleared | game-theme control only |

### UI

- **Main dropdown** (`#theme-select`): static themes only, all pages. The
  `game-theme-option` entries are removed. Selecting a static theme updates
  `theme` and applies it — it never touches `themeGameMatch`.
- **Game-theme control**: a second small `<select>` next to the main dropdown,
  same `.theme-select` styling, labeled with 🎨 (✨ is taken by the ambient
  motion toggle). Options: `Off` / `Game Light` / `Game Dark`. Hidden (like the current game options) unless the
  page contains `#game-theme`; visibility toggled by `syncTheme` on load and
  `phx:page-loading-stop`.

### Behavior rules

1. On any page load / LiveView navigation, `syncTheme` runs:
   - page has `#game-theme` **and** `themeGameMatch` is `game-light`/`game-dark`
     → apply that variant, game control reflects it, dropdown keeps showing the
     static theme (the fallback).
   - otherwise → apply static `theme`.
2. Choosing `Game Light`/`Game Dark` sets `themeGameMatch` and applies
   immediately (control only exists on pages where the palette is present).
3. Choosing `Off` clears `themeGameMatch`; the page falls back to the static
   theme immediately.
4. Selecting a static theme in the dropdown — on any page, including game
   pages — sets `theme` and applies it for the current page view, but does not
   clear `themeGameMatch`. (On a game page with an active game match, the next
   `syncTheme` re-applies the game variant; the dropdown is the fallback
   picker, the game control is the override.)
5. Theme-event tracking (`POST /theme-events`) fires from both controls, same
   payload shape as today; `RuleMaven.Metrics.game_themes/0` remains the label
   source for the game control options.

### Implementation surface

- `lib/rule_maven_web/components/layouts/root.html.heex` — markup for the two
  selects and the inline picker script (`apply`, `syncTheme`, listeners).
- No backend, schema, or LiveView changes. `GameTheme.style_block/1` unchanged.

### Edge cases

- Legacy `themeGameMatch = '0'` values in existing users' localStorage are
  treated as unset (the `isGameTheme` check already handles this).
- Users who currently have a game theme selected keep working: their
  `themeGameMatch` value carries over unchanged.
- Pre-paint script in `<head>` (flash-of-wrong-theme guard) stays as-is: it
  applies the static theme; `syncTheme` upgrades to the game variant right
  after, same as current behavior.

## Testing

- Manual in-browser verification (puppeteer + auto-login token, per existing
  convention): pick static theme on home → visit game Q&A with game-dark
  chosen → game theme applies; navigate away → static theme; pick a different
  static theme on home → return to Q&A → game theme still applies; set game
  control to Off → static theme on game page.
- No ExUnit surface changes (script + markup only); existing feature tests must
  stay green.

## Rejected alternatives

- **Keep game options in the dropdown, fix clearing behavior only**: least
  work, but keeps the confusing mixed-control UX that prompted this change.
- **Control in page body near cover art**: more discoverable in context, but
  splits appearance controls across two locations and needs per-page markup in
  both Show and FAQ.
