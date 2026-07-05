# Persona popularity rank + up-to-10 personas per game

## Problem

Per-game persona generation (`RuleMaven.Workers.VoiceSuggestionsWorker` →
`LLM.generate_voices`) currently invents 3–6 themed voices per game, capped at
6 in `LLM.parse_voices/1`. Display order is just LLM output order (persisted
as `game_voices.position`).

Two changes:

1. Raise the ceiling to 10 personas per game (still "fewer if theme is thin"
   — never pad).
2. Have the LLM additionally judge how popular each persona would be among
   fans of that specific game, store that rank, and use it to order the voice
   picker. This lays groundwork for a future plan-gated feature (e.g. free
   tier only sees the top N by rank) — that gating is explicitly out of scope
   here.

## Changes

### 1. Prompt (`RuleMaven.Prompts` — `generate_voices`)

- "Return between 3 and 6 voices" → "Return between 3 and 10 voices — fewer
  if the theme is thin; do not pad."
- Add `"popularity_rank"` to the JSON object shape: an integer, 1 = the
  persona this game's fans would most want to use, ascending, no gaps, unique
  per persona in the response.
- Add a rule explaining the field: judged by fit + fun for fans of *this*
  specific game, not generic appeal.

### 2. `LLM.generate_voices/2`

- `max_tokens` 8000 → 13000 (10 personas × 20+ loading phrases each is
  meaningfully bigger JSON than the current 6-persona ceiling).

### 3. `LLM.parse_voices/1` / `coerce_voice/1`

- `coerce_voice` extracts `popularity_rank` from the JSON; non-integer/missing
  → `999_999` (sorts last, never crashes on a malformed field).
- After mapping + dedup by slug, sort by `popularity_rank` ascending, then
  `Enum.take(10)` (raised from 6).

### 4. Migration

New column: `alter table(:game_voices) do add :popularity_rank, :integer end`.

### 5. `RuleMaven.Voices.GameVoice`

- Add `field :popularity_rank, :integer` to schema.
- Add to `cast` list in changeset. Not added to `validate_required` — a
  missing/malformed rank from a bad LLM response degrades gracefully (already
  defaulted to `999_999` upstream in `coerce_voice`) rather than failing the
  whole generation.

### 6. `RuleMaven.Voices.replace_generated/2`

- Pass `popularity_rank` through the `attrs` map (same as `description`,
  `loading_phrases`).
- Cache-invalidation rule is unchanged: only `style` or `label` changes clear
  cached restyles (`clear_for_voice`). A rank change alone does NOT clear the
  cache — rank doesn't affect the restyled text, only display order.

### 7. `RuleMaven.Voices.game_voice_defs/1`

- Query `order_by` becomes `[asc: gv.popularity_rank, asc: gv.position, asc: gv.id]`
  (was `[asc: gv.position, asc: gv.id]`). `position` (LLM output order) stays
  as the tiebreaker when ranks collide or are both the `999_999` fallback.
- Add `popularity_rank` to the `select` map returned to callers (harmless
  extra field; not currently consumed by `Voices.for_game/1`'s existing
  callers, but exposed for the future plan-gating feature to slice on).

## Out of scope

- Any plan/tier gating logic that limits which personas a user can select.
  This spec only makes the rank exist and drive default sort order.
- Changing global (`@voices`) persona ordering — globals are hand-authored
  and unranked, always shown in their fixed order before generated ones (per
  `Voices.for_game/1`'s existing `@voices ++ game_voice_defs(...)`).

## Testing

- Update existing `LLM.parse_voices` / `coerce_voice` tests for the new cap
  (10) and rank-sort behavior (out-of-order ranks in input JSON come back
  sorted; missing rank sorts last).
- Update `Voices.replace_generated/2` tests: rank-only change does not clear
  restyle cache; rank persists and reorders `game_voice_defs/1` output.
- Migration + schema test: `popularity_rank` round-trips through
  `GameVoice.changeset/2`.
