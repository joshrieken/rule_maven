# Game Theme Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Game Light/Dark out of the main theme dropdown into a separate 🎨 header control, and make the game-theme preference independent of (never cleared by) static theme selection.

**Architecture:** Front-end only. Two independent localStorage prefs: `theme` (static, main dropdown) and `themeGameMatch` (`game-light`/`game-dark`/`'0'`, game control). The game control is a second `<select>` in the header, hidden unless the page injects `#game-theme` (Q&A + FAQ pages). All logic lives in the inline picker script in the root layout.

**Tech Stack:** Phoenix root layout HEEx + vanilla inline JS. No backend changes.

**Spec:** `docs/superpowers/specs/2026-07-04-game-theme-split-design.md`

## Global Constraints

- Only file modified: `lib/rule_maven_web/components/layouts/root.html.heex`.
- `RuleMaven.Metrics.game_themes/0` (`[{"game-light","Game Light"},{"game-dark","Game Dark"}]`) stays the label source for the game control.
- Theme-event tracking (`POST /theme-events`) must fire from both controls.
- Legacy `themeGameMatch = '0'` treated as unset; existing `game-light`/`game-dark` values keep working.
- Pre-paint `<head>` script unchanged.
- Commit convention: end commit messages with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Split controls + picker script in root layout

**Files:**
- Modify: `lib/rule_maven_web/components/layouts/root.html.heex` (header controls ~lines 103–128; picker script ~lines 223–328)

**Interfaces:**
- Consumes: `RuleMaven.Metrics.themes/0`, `RuleMaven.Metrics.game_themes/0`, existing `#game-theme` style-block marker from `RuleMavenWeb.GameLive.GameTheme.style_block/1`.
- Produces: `#theme-select` (static themes only), `#game-theme-select` (Off/Game Light/Game Dark, hidden off game pages). localStorage contract: `theme` = static slug; `themeGameMatch` = `game-light` | `game-dark` | `'0'`.

- [ ] **Step 1: Replace the header selects markup**

In the `.header-controls` div, replace the current single select (with hidden `.game-theme-option` entries) with two selects:

```heex
<div class="header-controls">
  <select
    class="theme-select"
    id="game-theme-select"
    aria-label="Game theme"
    title="Match this game's colors on its Q&A and FAQ pages"
    hidden
  >
    <option value="0">🎨 Off</option>
    <option :for={{slug, label} <- RuleMaven.Metrics.game_themes()} value={slug}>
      🎨 {label}
    </option>
  </select>
  <select class="theme-select" id="theme-select" aria-label="Theme">
    <option :for={{slug, label} <- RuleMaven.Metrics.themes()} value={slug}>
      {label}
    </option>
  </select>
  <button
    type="button"
    class="motion-toggle"
    id="motion-toggle"
    aria-pressed="false"
    aria-label="Toggle ambient animations"
    title="Turn ambient animations on/off"
  >
    <span class="motion-toggle-on">✨</span>
    <span class="motion-toggle-off">🌙</span>
  </button>
</div>
```

(The `game-theme-option` loop inside `#theme-select` is deleted; the motion toggle is unchanged.)

- [ ] **Step 2: Rewrite the picker portion of the inline body script**

Replace everything in the body `<script>` IIFE from `var select = ...` down to (but not including) the `// Ambient-animation toggle.` section with:

```javascript
var select = document.getElementById('theme-select');
var gameSelect = document.getElementById('game-theme-select');
var html = document.documentElement;

// True when the current page exposes a per-game palette (the Q&A/FAQ pages
// inject `#game-theme`). The game control only appears here.
function gameThemeAvailable() {
  return !!document.getElementById('game-theme');
}

// The user's static theme — the look used everywhere a game palette isn't
// active. Never holds "game-light"/"game-dark".
function baseTheme() {
  var s = localStorage.getItem('theme');
  if (s) {
    var migrate = window.__themeMigrate || {};
    return migrate[s] || s;
  }
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'midnight' : 'lavender';
}

function isGameTheme(v) {
  return v === 'game-light' || v === 'game-dark';
}

// Sync both controls and the active theme to the current page: the chosen
// game variant wins on pages that offer one; otherwise the static theme.
// Re-run after LiveView navigations because `#game-theme` comes and goes.
function syncTheme() {
  var base = baseTheme();
  localStorage.setItem('theme', base);
  var available = gameThemeAvailable();
  gameSelect.hidden = !available;

  var match = localStorage.getItem('themeGameMatch');
  if (available && isGameTheme(match)) {
    html.setAttribute('data-theme', match);
    gameSelect.value = match;
  } else {
    html.setAttribute('data-theme', base);
    if (available) gameSelect.value = '0';
  }
  select.value = base;
}

syncTheme();
// LiveView swaps page content without a full reload; re-sync so leaving a
// game page can't strand us on the now-undefined game theme.
window.addEventListener('phx:page-loading-stop', syncTheme);

function track(value) {
  var meta = document.querySelector('meta[name="csrf-token"]');
  fetch('/theme-events', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-csrf-token': meta ? meta.getAttribute('content') : ''
    },
    body: JSON.stringify({ theme: value })
  }).catch(function() {});
}

// Static theme picker: sets the fallback theme only. Deliberately does NOT
// clear the game-match preference — that's the game control's job.
select.addEventListener('change', function() {
  localStorage.setItem('theme', this.value);
  html.setAttribute('data-theme', this.value);
  track(this.value);
});

// Game-theme control: opt in/out of matching the game's palette on pages
// that have one. Only rendered visible on those pages.
gameSelect.addEventListener('change', function() {
  if (isGameTheme(this.value)) {
    localStorage.setItem('themeGameMatch', this.value);
    html.setAttribute('data-theme', this.value);
    track(this.value);
  } else {
    localStorage.setItem('themeGameMatch', '0');
    html.setAttribute('data-theme', baseTheme());
  }
});
```

Note: when a static theme is picked while a game theme is active on a game page, the page shows the static theme for the current view; the stored `themeGameMatch` is untouched, so the next navigation/`syncTheme` re-applies the game variant (spec rule 4). The game control keeps showing the stored preference — it reflects the durable pref, not the transient view.

- [ ] **Step 3: Compile check**

Run: `mix compile --warnings-as-errors 2>&1 | tail -5`
Expected: compiles clean.

- [ ] **Step 4: Run existing tests (theme/layout surface)**

Run: `mix test 2>&1 | tee tmp/game-theme-split-test.log | tail -15`
Expected: all green (change is markup+script only; feature tests must not regress). Delete the log after the suite passes.

- [ ] **Step 5: Commit**

```bash
git add lib/rule_maven_web/components/layouts/root.html.heex
git commit -m "feat(theme): split game light/dark into separate header control

Game-match preference (themeGameMatch) is now independent of the static
theme: picking a static theme no longer clears it, so game pages return
to the chosen game variant even after theme changes elsewhere.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 2: In-browser verification

**Files:**
- None modified (verification only).

**Interfaces:**
- Consumes: Task 1's `#theme-select` / `#game-theme-select` controls and localStorage contract.
- Produces: verified behavior; no code.

- [ ] **Step 1: Start dev server + open browser session**

Use the existing puppeteer + auto-login token convention (see memory: layout-fixed-containing-block). Start `mix phx.server` if not already running.

- [ ] **Step 2: Verify the scenario matrix**

1. Home page: game select hidden; pick static theme (e.g. Ember) → `data-theme="ember"`, `localStorage.theme="ember"`.
2. Navigate to a game Q&A page (game with `theme_palette` set): game select visible, shows Off; page still `ember`.
3. Pick 🎨 Game Dark → `data-theme="game-dark"`, `themeGameMatch="game-dark"`, `theme` still `"ember"`.
4. Navigate home → `data-theme="ember"`; game select hidden.
5. Pick different static theme (e.g. Frost) on home → `theme="frost"`, `themeGameMatch` still `"game-dark"`.
6. Return to game Q&A → `data-theme="game-dark"` (game preference survived static change — the core fix).
7. Visit game FAQ page → also `game-dark`.
8. On game page, set game select to Off → `data-theme="frost"`, `themeGameMatch="0"`; navigate away and back → still `frost`.
9. Main dropdown contains no Game Light/Game Dark options anywhere.

- [ ] **Step 3: Check theme-event tracking**

While picking themes above, confirm `POST /theme-events` requests fire (network log or server log) for both controls' selections.

- [ ] **Step 4: Report results**

If any step fails, fix in `root.html.heex`, re-verify, amend/commit as a fix commit with the trailer from Global Constraints.
