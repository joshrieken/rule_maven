# House Rules Tracker — Design

Date: 2026-07-06. Picked from `2026-07-04-fun-features-backlog.md` (top pick #4).

## Problem

Groups accumulate house rules as tribal knowledge — nobody writes them down, new players get surprised, and nobody knows which house rules actually contradict the rulebook vs. fill genuine gaps. Rule Maven already has the rulebook, RAG retrieval, and verdict/citation infrastructure; this feature lets users log house rules per game and has the LLM classify each against rules-as-written (RAW).

## Decisions made during brainstorm

- **Ownership:** personal + community share. No group/table concept (app has none); a house rule belongs to a user, is private by default, and can be shared to the game's community list. Mirrors `questions_log` visibility (`"private"` → `"community"`).
- **Check output:** typed verdict + verbatim RAW quote + one-line note. Not stamp-only, not a full comparison essay.
- **Spend control:** each fresh check counts against `user.monthly_quota`, same budget as asks. Re-check after edit counts again.
- **UI:** a new card on the game show page (`game_live/show.ex`), beside setup checklist / did-you-know. No dedicated route.

## Data model

New table `house_rules`, context `RuleMaven.HouseRules` (`lib/rule_maven/house_rules.ex`):

| field | type | notes |
|---|---|---|
| `user_id` | fk, required | owner |
| `game_id` | fk, required | game scope (base game; expansion scoping is future work) |
| `title` | string, optional, ≤80 | list display |
| `body` | text, required, ≤500 | the house rule itself |
| `visibility` | string, default `"private"` | `"private"` \| `"community"` |
| `check_status` | string, default `"pending"` | `"pending"` \| `"done"` \| `"failed"` \| `"stale"` |
| `verdict` | string, nullable | see taxonomy |
| `raw_quote` | text, nullable | verbatim citation of the official rule |
| `check_note` | text, nullable | one-line LLM explanation |
| `citations` | jsonb, nullable | same shape as `questions_log.citations` |
| `checked_at` | utc_datetime, nullable | |
| `blocked` | boolean, default false | admin moderation kill for community rules |

Indexes: `[game_id, visibility]`, `[user_id, game_id]`.

## Verdict taxonomy

Four values, stored as strings, rendered as stamps (reuses verdict-stamp visual language):

- ✅ `matches` — RAW already allows/says this; house rule is redundant.
- 🧩 `fills_gap` — rulebook is silent; house rule covers uncovered territory.
- 🔀 `overrides` — replaces an explicit rule; `raw_quote` shows what it replaces.
- 🤔 `unclear` — retrieval weak or LLM couldn't determine.

"Contradicts" was deliberately dropped: any house rule touching an explicit rule is an override by definition; a separate contradicts label adds noise, not signal.

## Check flow

On create or body-edit:

1. `Security.prompt_injection?(body)` guard (same as AskWorker) — reject before any spend.
2. Quota gate (see below) — reject with clear flash if over.
3. Set `check_status: "pending"`, enqueue `Workers.HouseRuleCheckWorker`.

`HouseRuleCheckWorker`: `queue: :llm, max_attempts: 3, unique: [keys: [:house_rule_id]]` (VoiceWorker template). Steps:

- `Jobs.start_run("house_rule_check", {"house_rule", id}, label, oban_job_id: ...)` per job-log convention.
- Guard `Settings.asks_disabled?()` (global LLM kill switch applies).
- Embed rule text (`Embed.embed/1`), retrieve chunks via `Games.retrieve_chunks_for_games/3` — same RAG path as ask, context built with `build_context_block` authority ordering (errata > FAQ > rulebook).
- `LLM.chat` with registry prompts `house_rule_check` (user) + `house_rule_check_system` (system) — **both registered in `Prompts` `@specs`** (new group "House rules"), per standing rule. Strict-JSON output: `{verdict, raw_quote, note, citations}`. Modeled on the `grounding_critic` prompt shape. Operation `"house_rule_check"`, with `game_id`/`user_id` for cost attribution.
- Coerce verdict (unknown → `"unclear"`), persist results, `check_status: "done"` (or `"failed"` + note on refusal/error).
- Broadcast `{:house_rule_checked, house_rule_id}` on `"game:#{game_id}"`.
- `Jobs.finish_run`.

## Quota enforcement

Existing `Games.check_rate_limit/1` counts only `questions_log` rows. Extend: house-rule checks are counted from `llm_logs` rows with `operation == "house_rule_check"` for the user in the window, summed with the fresh-ask count against daily/weekly/monthly limits. No new tracking table; edits that trigger re-checks naturally count again. Admins bypass (existing behavior). The gate is evaluated before enqueue. Acceptable race: worker uniqueness per rule bounds it; worst case one extra check slips through, cost is one cheap call.

## Staleness

`Games.invalidate_pool/1` (rulebook change) additionally marks that game's house-rule checks `check_status: "stale"` (like `Voices.clear_for_game`). UI shows the old verdict greyed with a "re-check" button; re-check is user-triggered and counts against quota. No automatic re-check spend.

## UI (card on show.ex)

New 🏠 "House rules" card following the did-you-know/setup-checklist panel pattern (one LiveView, event + handle_info pairs, PubSub on `game:#{game_id}`):

- Sections: "Your house rules" (owner's, any visibility) and "Community house rules" (visibility community, not blocked, excluding own). Community rules visible to any viewer; create/edit/delete requires login.
- Per rule: title/body, verdict stamp, expandable RAW quote + note, pending spinner while `check_status == "pending"`, stale badge + re-check button when stale.
- Inline add form (title + body). Events: `add_house_rule`, `edit_house_rule`, `delete_house_rule`, `toggle_house_rule_visibility`, `recheck_house_rule`. Owner-only guards server-side on every mutating event.
- `handle_info({:house_rule_checked, id})` refreshes that rule in assigns.
- Admin (`Users.can?(user, :admin)`): block/unblock control on community rules.
- No raw ids in URLs (card is id-free; `phx-value` ids stay raw per convention).

## Error handling

- Prompt injection → rule not saved, flash explains.
- Over quota → rule save rejected with flash (invariant: every saved rule has a check queued or done; no permanently-unchecked rows).
- LLM refusal / persistent failure → `check_status: "failed"`, note shown, manual re-check available (counts quota).
- Suspended users already blocked at auth chokepoints.

## Testing

- Context tests: CRUD, visibility scoping, owner guards, stale marking on invalidate.
- Worker test (LLM stubbed): verdict coercion, refusal → failed, broadcast, Jobs log calls (`house_rule_check_worker_test.exs`).
- Quota test: llm_logs counting rolls into rate limit.
- LiveView test: card renders, add/edit/delete/toggle events, `{:house_rule_checked}` live update, admin block control gated.

## Future work (explicitly out of scope)

- Expansion-scoped house rules.
- Voting/flagging on community house rules (reuse `question_flags` pattern when needed).
- House-rule awareness in ask answers ("your table plays X differently").
