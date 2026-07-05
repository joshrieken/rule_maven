# Persona-direct answers + unified loading bar

## Problem

When a user asks a brand-new question with a non-default persona active,
today's flow is two sequential LLM calls:

1. `AskWorker` calls `RuleMaven.LLM.ask/5` → produces the neutral/canonical
   answer, persisted on `QuestionLog.answer`, pool-eligible.
2. Only once that lands does `apply_default_voice/2`
   (`show.ex:406-455`) enqueue `RuleMaven.Workers.VoiceWorker`, which calls
   `RuleMaven.Voices.restyle/5` → a second LLM call that rewrites the
   canonical answer into the persona's voice.

The UI shows a typing indicator through step 1, then switches to a
progress-bar loader (with persona flavor-text) through step 2. The user
never sees the plain answer rendered, but they do perceive two distinct
loading phases before the persona text appears — reported as "it first
generates plain then goes to that persona; should just do that persona."

`RuleMaven.Voices` deliberately isolates these two calls today: the
restyler "only ever sees the already-grounded answer text — never the
rulebook — so it cannot introduce new rules" (`voices.ex:11-13`). Removing
the two-call structure means giving up that isolation. The user has
confirmed this tradeoff is acceptable.

## Part 1 — Single-call, dual-output persona answer

For a **fresh ask** (not a pool/cache hit) where the asker's active
persona (`socket.assigns.default_voice`) is non-neutral, request both the
neutral and persona-styled answer from the *same* LLM call, instead of a
separate restyle round-trip.

### Threading the voice through

- `handle_event("ask", ...)` (`show.ex:672-812`) already has
  `socket.assigns.default_voice` in scope. Add it to the `AskWorker.new/1`
  args map (`show.ex:747-756`) as `"voice"`.
- `AskWorker.perform/1` (`ask_worker.ex:12-18`) reads `args["voice"]`
  (default `"neutral"`) and passes it through to `RuleMaven.LLM.ask/5` as a
  new `opts[:voice]`.
- `LLM.ask/5` (`llm.ex:35`) threads `opts[:voice]` down to `call_llm/7`
  only on the fresh-generation path — a cache/pool hit (`serve_from_cache/6`,
  `llm.ex:111-134`) never touches the LLM, so persona styling for a
  pool-hit answer still goes through the existing on-demand
  `Voices.restyle/5` path (unchanged).

### Prompt changes

- Extend the `"answer"` prompt's JSON schema (`prompts.ex:64-72`) with an
  optional key:
  ```
  "styled_answer": string  // OMIT this key entirely if VOICE below is "none".
                            // Otherwise: rewrite "answer" in VOICE's voice —
                            // same facts/numbers/citations, different tone.
  ```
- Add a `{{voice_style}}` binding to the `"answer"` template, rendered as
  an empty string when `voice == "neutral"` (schema instruction above then
  also degrades to "omit `styled_answer`"), or as a tone-instruction block
  adapted from `voice_restyle`'s guidance (`prompts.ex:441-454`: commit to
  the bit, rule comes first, keep facts/length identical, no sign-off
  unless one in-character phrase) when a persona is active. Reference the
  requested persona's `style` text (from `RuleMaven.Voices.get_def/2`).
- The existing "Strict JSON schema — keep the schema block intact or
  answering breaks" warning (`prompts.ex:685-688`) means this edit must be
  additive-only: the new key is optional and every other instruction stays
  byte-for-byte.

### Parsing and persistence

- `decode_answer/1` (`llm.ex:947-980`) additionally pulls
  `map["styled_answer"]` (nil-safe, absent key ⇒ `nil`).
- `call_llm/7`'s returned map (`llm.ex:166-187`) includes `styled_answer:
  ..., styled_voice: voice` (the voice that was requested, so the caller
  knows which persona the styled text belongs to).
- `AskWorker.perform/1`: unchanged persistence of `answer` (neutral) into
  `QuestionLog` as today. When `styled_answer` is present, additionally
  upsert an `answer_voices` row for `(question_log_id, styled_voice)` —
  reuse `RuleMaven.Voices` internal `store/3` (make it public, or add a
  `Voices.store_direct/3` wrapper) rather than duplicating the upsert.
  Skip enqueuing `VoiceWorker` for this pair since the cache is already
  populated.
- Broadcast `:ask_complete` (`ask_worker.ex:264-282`) gains
  `styled_voice`/`styled_answer` fields so the LiveView can populate
  `voice_cache` directly without a round-trip through `:voice_ready`.
- `GameLive.Show.handle_info({:ask_complete, ...})` (`show.ex:1252-1358`):
  before calling `apply_default_voice/2` (line 1345-1348), if
  `data[:styled_answer]` is present, `Map.put` it into `voice_cache` at
  `{question_log_id, data[:styled_voice]}`. `apply_default_voice/2`
  already skips voices already present in `voice_cache`
  (`show.ex:427-428`), so no redundant `VoiceWorker` job gets enqueued.

### Out of scope / unaffected

- Pool-hit answers, switching persona on an already-answered message, and
  per-game generated voices all keep using `Voices.restyle/5` exactly as
  today.
- No new DB migration: `answer_voices` already has the
  `(question_log_id, voice)` unique constraint used for the direct upsert.

## Part 2 — Always show the loading bar, never the typing dots

Today (`show.ex:2206-2249`) there are two distinct loading UIs:

- `msg.content == "Thinking..."` → three-dot typing indicator
  (`show.ex:2207-2216`).
- Non-neutral persona selected and its restyle/content not yet cached →
  progress-bar loader with rotating flavor phrases
  (`show.ex:2229-2244`).

Replace the typing-dot branch: whenever an answer isn't ready yet — either
still `"Thinking..."` (no answer at all) or persona content not yet
cached — render the same persona loading-bar component. Neutral persona
uses the generic phrase pool; a selected persona uses its own phrases
(Part 3). This also means, with Part 1 in place, a fresh ask with a
persona active now has exactly **one** loading phase (single LLM call),
matching "just do that persona" — no interim reveal, no visible
handoff between two different loaders.

Failure fallback is unchanged: `voice_failed` still falls through to
plain text with the existing flash message
(`show.ex:1393-1401`).

## Part 3 — Bigger, non-mixed per-persona phrase sets

- Expand each built-in persona's `loading:` list (`voices.ex:58-117`) from
  ~5 entries to a sizeable set (~15-20), written in that persona's voice —
  `lawyer`, `pirate`, `robot`, `coach`.
- `loading_phrases/2` (`voices.ex:195-204`) stops concatenating
  `@generic_loading` onto a voice's own list. New behavior: return the
  voice's own phrases if non-empty, else fall back to `@generic_loading`.
  This means:
  - A built-in persona (now with its own big list) never shows generic
    phrases mixed in.
  - Neutral (no persona) still uses `@generic_loading` (unchanged, since
    "neutral" has no `loading:` entry).
  - A per-game generated voice with no `loading_phrases` set still falls
    back to `@generic_loading` (unchanged behavior for that case).

## Testing

- Unit: `Voices.loading_phrases/2` no longer mixes generic phrases in for
  a built-in persona; still falls back to generic for neutral / phrase-less
  generated voices.
- Unit: `LLM.ask/5` / `decode_answer/1` with a mocked JSON response
  containing `styled_answer` correctly threads both fields through;
  absent key ⇒ `nil`, no crash.
- Unit: `AskWorker` persists neutral `answer` and upserts `answer_voices`
  when `styled_answer` is present; does not enqueue `VoiceWorker` for that
  `(question_log_id, voice)` pair.
- Feature/LiveView: fresh ask with a persona active renders the loading
  bar (not typing dots) throughout, then the persona-styled text appears
  directly with no intermediate plain reveal.
