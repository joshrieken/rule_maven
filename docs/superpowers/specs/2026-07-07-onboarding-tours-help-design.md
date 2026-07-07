# Onboarding Tours + Help Page — Design

Date: 2026-07-07. Approved by user in brainstorming session.

## Goal

Short, sweet onboarding for new users covering the most important features, plus a
help page with a guide and FAQ. Tours replayable anytime from the user dropdown.

## Tour engine (custom, no external lib)

- JS hook `Tour` in `assets/js`: dimmed backdrop with spotlight cutout over the
  target element, tooltip card (title, body, Back/Next/Skip, progress dots),
  scrolls target into view, Esc/Skip ends. Missing element → step auto-skipped.
- Targets tagged with `data-tour="..."` attributes — stable selectors.
- Step content lives server-side in `RuleMavenWeb.Tours`; pushed to the hook via
  `push_event("tour:start", %{steps: [...]})`.

## Tours

1. **Games list** (`GameLive.Index`, ~4 steps): search, game card + "Ready"
   status, favorites/collection, import game.
2. **Game page** (`GameLive.Show`, ~7 steps): ask box, suggested questions,
   expansions selector, answer voices, setup checklist, did-you-know card,
   house rules card. Final step points at the Help page.
   Votes/confidence only exist after an answer; covered in Help instead.

## Persistence + triggers

- New jsonb column `users.tours_seen` (map, default `{}`), keyed by tour id
  (`"games"`, `"game"`) → ISO8601 timestamp.
- Auto-start on mount when a logged-in user lacks the key for that page's tour.
  Complete/skip → `tour_done` event → `Users.mark_tour_seen/2`.
- Anonymous users: no auto-start, no replay (tours are a logged-in feature).
- **Replay** via user dropdown: "Tour: Finding games" and "Tour: Asking
  questions". Games tour navigates home and starts. Game tour starts in place on
  a game page; elsewhere sets a pending flag (localStorage) and auto-runs on the
  next game page mount, with a flash prompting to open a game.

## Help page

- `/help`, public, static controller-rendered HEEx page.
- Guide sections: What is RuleMaven (incl. AI-fallibility disclosure), Finding
  games, Asking questions (expansions, voices), Understanding answers
  (confidence meter, verdict stamps, source names — never rulebook files),
  Community (votes, game FAQ, house rules, curator points/badges), Quotas.
- FAQ: ~12 `<details>` accordions, zero JS.
- Linked from: user dropdown, mobile drawer, final tour step.

## Testing

- Unit tests: `mark_tour_seen/2`, `tour_seen?/2`, auto-start decision.
- LiveView/controller tests: dropdown items, `/help` renders, tour data pushed.
- JS hook verified manually in browser (major behavior change).
