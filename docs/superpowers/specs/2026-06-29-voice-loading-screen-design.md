# Voice loading screen — design

**Date:** 2026-06-29

## Goal

When a user switches to a persona voice whose restyle isn't cached yet, replace the
visible answer text with a SimCity-style loading panel — a cycling nonsense phrase,
a faux progress bar, and a retro spinner glyph — until the restyled answer arrives
over PubSub. Today the old (neutral or previously-cached) text stays on screen with a
small "🎭 putting it in character…" caption; that caption and the stale text are both
replaced by the loader.

## Behavior

- Trigger: `v_pending && is_nil(v_content)` for an answer (`show.ex` ~lines 2032-2039).
  This is exactly the "uncached voice selected, restyle in flight" state.
- While pending: render the loader **instead of** `msg.content`. The previous text is
  cleared (the core ask).
- On `{:voice_ready, ...}`: existing PubSub handler fills `voice_cache`, `v_content`
  becomes non-nil, loader is replaced by the restyled markdown. No new server messaging.
- On `{:voice_error, ...}`: existing handler clears pending; `v_content` stays nil so it
  falls back to `msg.content` (neutral) — loader disappears, original text returns.
- Neutral never pends, so the loader never shows for neutral.

## Phrase sources (voice-flavored)

Three layers, resolved by a single helper:

1. **Global voices** — add a `loading: [phrase, ...]` list to each entry in
   `RuleMaven.Voices` `@voices` (skip `neutral`). 4-6 short in-character phrases each
   (e.g. Rules Lawyer: "Filing the motion…", "Citing precedent…"; Pirate: "Swabbing the
   rules…", "Consulting the charts…").

2. **Generated game voices** — the LLM returns them. Add `loading_phrases` (list of
   strings) to the `generate_voices` JSON object shape and prompt. Stored in a new
   `loading_phrases` column on `game_voices`.

3. **Generic fallback pool** — a shared, board-game-themed nonsense list defined in
   `Voices` (e.g. "Reticulating splines", "Consulting the errata", "Bribing the rules
   lawyer", "Re-shuffling the meeples", "Aligning the hex grid", "Waking the rules
   lawyer"). Used when a voice has no phrases of its own, and always blended in so the
   panel never looks sparse.

### Resolver

```elixir
# Voices.loading_phrases(voice, game) :: [String.t()]
# Returns the voice's own phrases (global @voices :loading, or generated
# loading_phrases column) concatenated with the generic pool, de-duplicated.
# Falls back to generic-only when the voice has none.
```

## Data model

- Migration: add `loading_phrases` to `game_voices` as a Postgres `{:array, :string}`
  column, nullable (no default needed; treat nil as empty).
- `GameVoice` schema: `field :loading_phrases, {:array, :string}, default: []`; add to
  `changeset` cast list (not required).
- `Voices.game_voice_defs/1`: select and expose `loading_phrases` on the def map.
- `Voices.replace_generated/2`: persist `loading_phrases` from parsed LLM output.
- **No backfill.** Pre-existing generated voices have nil/empty → generic fallback until
  the game's voices are regenerated.

## LLM prompt change

In `Prompts` `@generate_voices`:
- Add `"loading_phrases"` to the documented JSON object shape: an array of 4-6 very short
  (≤ ~5 words) in-character "loading screen" status lines themed to that persona — playful
  nonsense in the spirit of old SimCity loaders, NOT rules or facts.
- `LLM.parse_voices/1`: tolerate a missing `loading_phrases` (default `[]`); coerce to a
  list of strings.

## UI

In `show.ex`, replace the pending block (~2032-2039):

```heex
<div class="answer-in">
  <%= if v_pending && is_nil(v_content) do %>
    <div
      class="voice-loader"
      id={"voice-loader-#{msg[:id]}"}
      phx-hook="VoiceLoader"
      phx-update="ignore"
      data-phrases={Jason.encode!(Voices.loading_phrases(v_sel, @game))}
    >
      <div class="voice-loader__row">
        <span class="voice-loader__spinner" aria-hidden="true"></span>
        <span class="voice-loader__phrase">…</span>
      </div>
      <div class="voice-loader__bar"><div class="voice-loader__fill"></div></div>
    </div>
  <% else %>
    {render_markdown(v_content || msg.content)}
  <% end %>
</div>
```

- `phx-update="ignore"` so LiveView re-renders don't reset the hook's animation while
  pending.

## JS hook (`priv/static/assets/js/app.js`)

`Hooks.VoiceLoader`:
- `mounted()`: parse `data-phrases`; start two timers.
  - Phrase timer (~700ms): pick a random phrase (avoid immediate repeat), write it into
    `.voice-loader__phrase`.
  - Bar timer (~250ms): advance `.voice-loader__fill` width by eased random jumps toward
    ~90% (never visually "completes" — the real completion is the content swap), with an
    occasional small reset for retro flavor.
  - Spinner: CSS-animated retro glyph (spinning braille/ASCII via CSS `@keyframes` and
    `content` steps), no JS needed beyond a class.
- `destroyed()`: clear both timers.

## CSS

Add `.voice-loader*` rules near the existing chat styles (themeable via
`var(--accent)`, `var(--bg-subtle)`, `var(--text-muted)`):
- `.voice-loader__bar` track + `.voice-loader__fill` accent fill with a width transition.
- `.voice-loader__spinner` retro stepped spinner keyframes.
- Compact, italic muted phrase text consistent with the current caption styling.

## Testing

- `Voices.loading_phrases/2`: returns generic pool for an unknown/neutral voice; returns
  global voice phrases ++ generic for a global; returns generated `loading_phrases` ++
  generic for a `g:` voice; never returns an empty list.
- `LLM.parse_voices/1`: parses objects with and without `loading_phrases`; coerces/omits
  non-string entries; defaults missing to `[]`.
- `GameVoice` changeset: accepts and round-trips `loading_phrases`.
- JS hook + CSS verified in-browser (puppeteer + auto-login token) by switching to an
  uncached voice and confirming the old text clears and the loader animates.

## Out of scope (YAGNI)

- Regenerating/backfilling existing games' voices — generic fallback covers them.
- Server-driven phrase cycling — purely client-side.
- LLM-generated phrases per restyle — phrases are authored once per voice.
