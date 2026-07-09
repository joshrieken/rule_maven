# Game sub-bar parity across every user-facing game page

**Date:** 2026-07-09
**Status:** Approved, pending implementation

## Problem

`SubBar.game_header/1` is already rendered by all five user-facing,
game-specific LiveViews — Show, Community, Prepare, Review and the Edit form —
with identical props, and each page mounts the tools and handles the tool
events. The *component* is shared. What is not shared is everything wrapped
around it, so the bar looks like a different control on Show than it does
anywhere else:

1. **Chrome.** Show wraps the header in a `.chat-header` div carrying inline
   styles: `--bg-surface` background, a bottom border, and `z-index: 20`,
   spanning the full viewport. The other four render the header bare, inside a
   centered `max-width: 52rem` padded column, so it has no background, no
   border, and floats over the blurred game art.
2. **Right-side pills.** Show fills the header's `inner_block` slot with the
   Rulebooks dropdown, the Community Q&A pill and the Cheat Sheet link. The
   other four pass no slot content, so their right side is empty.
3. **Scroll behaviour.** Show's bar never scrolls away, because `.chat-layout`
   is a fixed app shell and only the chat area scrolls beneath it. The other
   pages are ordinary scrolling documents, so their bar scrolls off the top.

## Goal

Every user-facing game page wears the same bar: same chrome, same pills, pinned
to the top of the scroll container. Admin pages are out of scope. The games
list (`/`) and the import page are not game-specific and get no bar.

`/games/:id/cheatsheet` is user-facing and game-specific but is a plain
controller that `send_resp`s a standalone printable HTML document via
`CheatSheet.wrap_html_for_serve/2`. It has no app chrome and no LiveView, so it
cannot host a working sub-bar without being converted. **Out of scope**;
revisit separately.

### Deliberate duplication

The More menu already lists Rulebooks, Cheat Sheet and Community Q&A, and the
`SubBar` moduledoc warns that "a page that also paints them as loose links is
showing the same destination twice." Show does exactly that today: the pills are
`hide-mobile` desktop shortcuts and the More menu is the mobile path to the same
destinations. We are propagating Show's behaviour verbatim, so this duplication
is intentional and preserved, not introduced.

## Design

### 1. Component — `lib/rule_maven_web/live/game_live/sub_bar.ex`

**New `game_bar/1`.** A chrome wrapper that renders `game_header` inside a
`<div class="game-bar">`. Pages call `game_bar`; `game_header` becomes its
implementation detail. The `inner_block` slot passes through.

**`game_header` gains `current`**, an atom — one of `:show`, `:community`,
`:prepare`, `:review`, `:edit`.

`current` **replaces** the existing `on_game_page` boolean. The two would always
agree (`on_game_page == (current == :show)`), and `current` carries strictly
more information. Keep the patch/navigate split it controls: `current == :show`
patches to the overview, everything else navigates, because patching across
LiveViews crashes.

**New private `header_pills/1`.** The Rulebooks dropdown, Community Q&A pill and
Cheat Sheet link move out of Show's slot and into the component, rendered in the
`.game-header-row__right` region on every page. A pill whose destination equals
`current` renders as an active, non-navigating element with `aria-current="page"`
— it keeps its place so the bar's shape does not shift between pages.

Only Show and Community have a pill that can be current. Prepare, Review and
Edit are More-menu items with no pill of their own, so on those pages `current`
only governs patch-vs-navigate.

Show's `inner_block` slot survives, but now carries only its `☰` sidebar toggle.

Two problems surface the moment the pills leave `show.ex`:

- **`↻ Regen` has no handler off Show.** The Rulebooks dropdown contains an
  admin-only button wired to `phx-click="regenerate_html"`, and that handler is
  defined only in `show.ex`. Rendering it on Community would crash for admins on
  click. Gate the button to `current == :show` rather than plumb the handler
  through `ToolHost` — admins reach regeneration from the Review page anyway.

- **The Cheat Sheet test is a per-render N+1.** Its visibility condition is
  `Enum.any?(@sources, &(CheatSheet.active_version(&1.id) != nil))` — one query
  per source, every render. Show pays this today; copying it to five pages
  multiplies it. Hoist it to a `:has_cheatsheet` assign computed once at mount
  (below) and have the component read the assign.

### 2. Assigns — `lib/rule_maven_web/live/game_live/tool_host.ex`

`mount_header/2` gains `put_new(:has_cheatsheet, fn -> … end)`, alongside the
existing `coarse_pointer`, `is_admin`, `sources` and `community_count`.

Show and Community assign their header data by hand today and never call
`mount_header/2`. They call it now. Because every key goes through `put_new/3`,
their existing assigns win and no query is issued twice.

### 3. CSS — `priv/static/assets/css/app.css`

```css
.game-bar {
  position: sticky; top: 0; z-index: 20;
  padding: 0.25rem 0.75rem;
  background: var(--bg-surface);          /* opaque: game art scrolls under it */
  border-bottom: 1px solid var(--border);
}
.game-bar .game-header-row { margin-bottom: 0; }
.main-content:has(.game-bar) { padding-top: 0; }
```

Show's header div swaps its inline styles for `class="chat-header game-bar"`,
keeping `flex-shrink: 0`. Both then paint from one rule and cannot drift. The
existing `.chat-header .game-header-row { margin-bottom: 0 }` rule folds into
`.game-bar` and is deleted.

Two constraints this respects, each of which has bitten this codebase before:

- **Sticky measures from `.main-content`'s padding box**, not its content box,
  so any top padding strands the bar in a blank band below the header. This is
  the same fix `.main-content:has(.game-list)` already applies for
  `.list-controls`.
- **A transformed ancestor becomes the containing block** for fixed and sticky
  descendants. `.main-content:has(.chat-layout, .blur-bg)` already disables the
  `content-rise` animation on every one of these pages, so no lingering
  transform remains. Sticky is safe without further change.

The background must be opaque, or the blurred game art shows through the bar as
content scrolls beneath it.

### 4. Templates

In `community.ex`, `prepare.ex`, `review.ex` and `form.ex`, `game_bar` moves out
of the centered column and sits directly after `blur_background`, as a sibling
preceding the content wrapper. The bar then spans the viewport while page
content stays centered. Each page passes its own `current`.

`form.ex` keeps its `:if={@game}` guard — the Add Game route has no game yet and
keeps its plain row.

`show.ex` keeps the bar inside its chat chrome, passes `current={:show}`, and
reduces its slot to the `☰` toggle.

Pills remain `hide-mobile`, so at 390px the right side is empty on every page —
exactly how Show behaves today.

## Testing

- A LiveView render test per page (five) asserting the bar renders with its
  pills.
- A test asserting Community's own pill is active and carries no `href`.
- A test asserting `↻ Regen` renders on Show for an admin and on no other page.
- Manual verification of all five pages at 390px, per the mobile-first rule.

## Out of scope

- Converting `/games/:id/cheatsheet` to a LiveView.
- Admin pages, the games list, the import page.
- Any change to the More menu's contents.
