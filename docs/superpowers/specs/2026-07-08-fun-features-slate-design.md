# Fun Features Slate — Design (2026-07-08)

## Context

Per-game engagement today is strong but skews **solo, pre-game prep**: verdict
stamps, confidence meter, personas/voices, DYK card, setup checklist, voice-ask,
rule-of-day, first-player picker, common mistakes, argument settler, quiz, turn
timer, asker achievements, house-rule stamps, cheat sheet.

Two whitespaces remain: **during-play tools** (things you touch mid-session at
the table) and **social/live** (group engagement). This doc designs a slate
across three veins — During-play, Social/live, Flavor/identity — each specced to
fit the existing architecture so any subset can be picked up independently.

### Architecture the slate reuses

- **Generate → cache → render.** Content-y features are produced at
  rulebook-finalize by an Oban worker (`lib/rule_maven/workers/*_worker.ex`),
  cached as an `app_settings` row keyed `"<feature>_<game_id>"`, loaded by a
  `load_*` helper in `game_live/show.ex`, rendered on the game page.
- **Prompts registry.** Every LLM prompt (system + user) is a `@specs` entry in
  `lib/rule_maven/prompts.ex` with admin override — never hardcoded.
- **Verify pass.** Fact-y generators pair a `<feature>` prompt with a
  `<feature>_verify` critic (see `did_you_know`, `common_mistakes`).
- **Client hooks.** Interactive/stateful UI uses JS hooks (`TurnTimer`,
  `ChecklistStore`, `VoiceDictation`) with per-browser `localStorage`.
- **Existing gamification.** `Games.Curation` (curator points, badges, asker
  achievements/streaks), `users.reputation/curator_points/monthly_quota`.
- **Personas.** `Voices` + `GameVoice` (`g:<slug>`), `PersonaEvent` popularity.

### Cross-cutting requirements (apply to every feature below)

- New user-facing feature ⇒ update `/help` guide + FAQ and tours.
- LLM prompts land in the registry, each guarded by the LANGUAGE rule.
- No raw ids in URLs — opaque hashids.
- Any new ask-style LLM call obeys quota + daily $ cap; cache hits are free.
- Buttons use shared `btn-*` classes; accent from theme vars.

---

## Vein A — During-play tools

### A1. Turn Wizard — "What can I do now?" (flagship, effort L)

**What.** An interactive stepper of a single turn. Instead of a wall of text,
the player picks their current phase and sees the legal actions available *right
now*, each with a one-line rule + citation, plus "then what" transitions.

**UX.** Card on the game page: "It's your turn →". Opens a modal stepper.
Node = phase (e.g. Upkeep → Action → Buy → Cleanup); each node lists allowed
actions and branches. Back/forward, "restart turn". Mobile-first.

**Architecture.** New worker `turn_flow_worker.ex` generates a **turn-structure
tree** (JSON: ordered phases, each with actions[{label, rule, citation}],
optional branches) grounded in the rulebook chunks, gated by a
`turn_flow_verify` critic. Cache `app_settings "turn_flow_<game_id>"`. Loader
`load_turn_flow/1` in `show.ex`; render via a new `TurnWizard` JS hook (pure
client navigation over the cached tree — zero LLM at play time). Prompts:
`turn_flow_generate` (+`_system`), `turn_flow_verify`.

**Why flagship.** Highest during-play utility; solves the real table pain ("wait,
what can I even do?"). All cost paid at finalize, free at the table.

**Risk.** Games with non-linear/simultaneous turns don't map to a clean tree —
prompt must emit a "freeform" fallback node and the UI must degrade to a plain
phase list. Weight-driven: only worth generating for games with a defined turn
structure; skip trivially-simple ones.

### A2. Score Pad + end-game ceremony (effort M)

**What.** A tally sheet using the game's *actual* scoring categories, plus a
themed "and the winner is…" reveal card at the end.

**UX.** "Score pad" card → add players → per-category inputs (generated
categories, e.g. Catan: longest road, largest army, VP cards…) → running totals
→ "Reveal winner" ⇒ ceremony card (winner, margin, a one-line flavor line in the
game's theme) that's shareable.

**Architecture.** Worker `score_categories_worker.ex` → cached
`"score_categories_<game_id>"` (list of {label, hint, max?}). All tally state
client-side (`ScorePad` hook, `localStorage`, no server round-trips, no PII).
Ceremony flavor line reuses a persona/theme prompt at generate-time (a few
canned templates cached with the categories, picked client-side — no per-game
LLM at reveal). Prompts: `score_categories_generate` (+`_system`).

**Note.** Some games aren't score-based (co-op/legacy). Prompt returns
`scoring: none` ⇒ hide the card.

### A3. Scenario Simulator (effort S — thin wrapper)

**What.** "What happens if…?" — describe a board state, get a ruling + likely
follow-up questions.

**Architecture.** Mostly reuses the **ask pipeline** and overlaps the existing
**argument settler**. Recommendation: implement as a *specialized ask
entrypoint* (a modal that frames the question as a hypothetical and appends the
suggested-questions follow-ups), not a new subsystem. One new prompt
`scenario_frame` layered on the existing `answer` prompt. Counts against quota
like any ask. **Lowest novelty — include only if cheap; otherwise cut (YAGNI).**

---

## Vein B — Social / live

### B1. Settled-Arguments Wall (effort S — best quick win)

**What.** A public per-game feed of resolved argument-settler verdicts: "Player A
said X, Player B said Y → ⚖️ ruling." Funny *and* useful; social proof.

**Architecture.** Pure read over existing data — argument-settler results are
already `question_log` rows. Add a boolean/kind marker when a settle produces a
verdict (or filter on the existing settle path), then a section on
`GameLive.Community` (or a `/games/:id/arguments` tab) listing recent settled
disputes, most-upvoted first. Reuses vote/visibility/trust plumbing. No new LLM.

**Moderation.** Runs through existing visibility + moderation signals; disputes
inherit the same abuse gating as questions.

### B2. Rules Race — multiplayer quiz + leaderboard (effort M)

**What.** The existing solo quiz, made competitive: a shared per-game leaderboard
and an optional "race" (same question set, fastest correct wins).

**Architecture.** Reuses `quiz_worker` content wholesale. Add a `quiz_score`
schema (`user_id, game_id, score, best_time, taken_at`) + a leaderboard query;
render on the game page + `/standing`. Live race = a lightweight
`Phoenix.PubSub` room keyed by game + a share code (opaque token), players join,
questions advance in lockstep, scores broadcast. Start with **async leaderboard
only** (no realtime) as phase 1; realtime race as phase 2.

**Gamification tie-in.** Feeds per-game mastery (C3).

### B3. Live Table Room (effort L — biggest, defer)

**What.** One share-code; the whole group asks in a single shared Q&A thread
during a session. Everyone sees questions + answers live.

**Architecture.** New `Room` schema (game, opaque join code, ttl), `Presence` +
`PubSub`, a shared `GameLive.Room` LV. Questions still flow through the normal
ask pipeline/quota (attributed to each asker). Heaviest item: new schema,
presence, auth for anonymous joiners, abuse surface. **Recommend deferring to a
later phase**; B1/B2 deliver most of the social value first.

---

## Vein C — Flavor / identity

### C1. Faction / Character Personality Quiz (effort M — high share potential)

**What.** "Which faction/character are you?" — a themed personality quiz that
maps answers to a role in the game. Strong shareable moment.

**Architecture.** Only for games with distinct factions/characters — gate on a
generate-time check (prompt returns `applicable: false` ⇒ no card). Worker
`faction_quiz_worker.ex` → cached `"faction_quiz_<game_id>"` (questions[],
outcomes[{faction, blurb, emoji}], scoring map). Fully client-side play
(`FactionQuiz` hook), result renders a share card. Pairs with the existing
clipboard-copy share; a real PNG export is a stretch (none exists today).
Prompts: `faction_quiz_generate` (+`_system`), `faction_quiz_verify` (names must
be real in-game factions, not invented).

### C2. Read-Aloud Narrator / TTS (effort S)

**What.** A "🔊 read aloud" button that speaks the setup steps or an answer in a
persona voice. Pairs naturally with existing voices.

**Architecture.** Browser `SpeechSynthesis` API, client-only (`ReadAloud` hook).
No server, no cost. Voice/pace tuned per persona (map `GameVoice`/built-in voice
→ speech params). Progressive enhancement: hide where the API is absent.

### C3. Per-Game Mastery badges (effort M)

**What.** Achievements tied to a *specific* game — "Catan Scholar", "Wingspan
Sage" — not just the global asker streak. Rewards depth in one game.

**Architecture.** Extend `Games.Curation` — the data exists (`question_log`
carries `game_id` + `user_id`; quiz scores from B2). Define per-game thresholds
(questions asked, quiz high score, arguments settled, days active) → badges shown
on the game page and `/standing`. Reuses the existing badge UI in
`standing_live.ex`. No LLM.

### C4. 60-Second Teach (effort S)

**What.** An auto-generated elevator pitch: "Teach this game in 60 seconds" —
goal, core loop, win condition, the one rule newbies miss.

**Architecture.** Worker `teach_pitch_worker.ex` → cached
`"teach_pitch_<game_id>"`; loader + card on the game page. Overlaps DYK/common-
mistakes tone — keep it distinct (a *structured teach*, not trivia). Prompts:
`teach_pitch_generate` (+`_system`), `teach_pitch_verify`.

---

## Recommended phasing

Ranked by (fun × reach) ÷ effort:

1. **Phase 1 — quick wins & flagship**
   - B1 Settled-Arguments Wall (S, reuses existing data)
   - C2 Read-Aloud Narrator (S, client-only)
   - C4 60-Second Teach (S, standard generate-pattern)
   - A2 Score Pad + ceremony (M, high table utility)
   - A1 Turn Wizard (L, flagship — start prompt design early)
2. **Phase 2 — competitive & identity**
   - B2 Rules Race leaderboard (async first)
   - C1 Faction Quiz
   - C3 Per-Game Mastery badges
3. **Phase 3 — heavy social (evaluate demand first)**
   - B2 realtime race
   - B3 Live Table Room
   - A3 Scenario Simulator (only if not cut)

## Open questions

- **Game-page real estate.** ~14 fun features already live on `show.ex` (~5000
  lines). New cards need a home — likely a collapsible "Play & fun" section or a
  dedicated tab rather than more stacked cards. Worth a small IA pass before
  Phase 1 lands.
- **Generate cost.** Each new generator adds LLM spend at finalize per game. Gate
  weak-fit games (turn wizard for simultaneous-turn games, score pad for co-ops,
  faction quiz for factionless games) via `applicable:false` returns.
- **PNG share.** Faction quiz + ceremony card want image export; none exists
  today (only clipboard + cheat-sheet download). Decide client-canvas render vs.
  defer to clipboard/text.
