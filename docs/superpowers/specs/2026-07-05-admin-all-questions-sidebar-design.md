# Admin "All Questions" in Q&A sidebar

## Problem

Admins can already browse every question across every user/game via
`/admin/questions` (`AdminLive.Questions`, admin_list_questions/1, games.ex:2039)
and inspect a single answer's edit history via the per-answer version-history
panel inline in `game_live/show.ex` (`toggle_question_history`,
~show.ex:1001-1020, backed by `Audit.question_history/2`).

But the two don't connect: the in-context "My Questions" sidebar while playing
a specific game is scoped to `user_id` only (`show.ex` ~1808-1970,
`base_question_query` filtered by current user). To see what *other* users
asked about the game the admin is currently looking at, they must leave the
game view, go to `/admin/questions`, filter by game — losing the in-context
thread view (citations, canonical answer, version history) that only renders
inline in `show.ex`.

Goal: let an admin, while in a game's Q&A view, see and search every
question asked about that game by any user, and open any of them inline with
full admin capability — without leaving the page.

## Design

### Scope & gating

Admin-only (`Users.can?(current_user, :admin)`), inside
`rule_maven_web/live/game_live/show.ex`. Non-admin behavior is unchanged:
they still see their own "My Questions" (time-grouped) and "Not Covered"
sections exactly as today.

### Sidebar section changes (admin view only)

- **"My Questions" → "All Questions."** Same time-grouping (Today / Last 7
  Days / Older) as today, but the underlying query is no longer filtered by
  `user_id` — it pulls every `QuestionLog` row for the current game, across
  all users. Each row is tagged with the asker's name; the admin's own
  questions are tagged "You."
- **"Not Covered" section removed for admins.** Refused questions already
  appear in their normal time slot within All Questions (all statuses are
  included there), so the separate refused-only section would just be
  showing duplicates. Non-admins keep "Not Covered" as-is.
- Community and Favorites sections: unchanged for everyone.

### Data loading

New `Games` context function, e.g. `Games.list_all_questions_for_game(game_id)`,
preloading `:user`. This is distinct from `admin_list_questions/1`
(games.ex:2039), which is cross-game/global and backs `/admin/questions`; the
new function is per-game and backs this sidebar section. No pagination or cap
— loads the full set for the game on mount/param-change, same lifecycle as
the existing per-user query it replaces for admins. (Tradeoff accepted:
very-high-traffic games could mean a large in-memory list; revisit with a cap
or lazy-load later if this becomes a real perf issue.)

### Search

The sidebar's existing text search box (`phx-change="search"`, in-memory
filter over the loaded question list) is extended to also match against the
asker's name/email, not just question/answer text. Applies uniformly: for
admins it searches across All Questions (all users); for non-admins it
continues to search only their own questions. No separate search UI.

### Interaction

Clicking any row in All Questions — whether it's the admin's own question or
another user's — opens the **same inline thread view** already used for own
questions today: full Q&A content (citations, canonical answer), plus every
existing admin control (edit canonical answer, set visibility, delete, open
the version-history panel via `toggle_question_history`). No new permission
checks are introduced: today those actions are already gated per-action by
admin checks, independent of whose question is open. This change only alters
*which* questions are reachable from the sidebar — not what an admin can do
once one is open.

## Testing

- Unit test: `Games.list_all_questions_for_game/1` returns rows from
  multiple users for a game, preloaded with `:user`.
- LiveView test: as admin, mount `game_live/show.ex` for a game with
  questions from other users — assert "All Questions" section (not "My
  Questions") renders, includes other users' rows tagged with their name,
  admin's own tagged "You", and "Not Covered" section is absent.
- LiveView test: as non-admin, same game — assert "My Questions" (own-only)
  and "Not Covered" still render as today; no other-user rows visible.
- LiveView test: search box input matching another user's name/email filters
  to that user's questions within All Questions.
- LiveView test: admin clicks another user's question row — inline thread
  view opens with full content; admin can invoke existing actions (e.g.
  `toggle_question_history`, `set_visibility`) against it successfully.
