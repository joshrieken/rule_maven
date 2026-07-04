# Difficulty Badge Design

## Purpose

Show a lightweight complexity indicator ("Light" / "Medium" / "Heavy") on the game show page, sourced from BGG's community-rated `averageweight` field. No LLM cost — pure data pull + render heuristic.

## Data model

- Migration: add `weight :float` (nullable) to `games` table.
- Range matches BGG's own scale, roughly 1.0–5.0.

## BGG import changes

- `lib/rule_maven/bgg.ex` `parse_game_info/1` (currently ~line 281-310) parses `year_published`, `min_players`, `max_players`, `playing_time`, `image_url`, `thumbnail_url`, expansion links via xpath, but does **not** currently parse `statistics/ratings/averageweight` even though it's present in the BGG XML response.
- Add an xpath query for `averageweight` alongside the existing fields.
- Cast the parsed value into the `Game` changeset. (Note: `thumbnail_url` is currently parsed but silently dropped in the changeset cast list — `weight` must not repeat that mistake; verify it's actually persisted.)
- Raw XML is already cached per-game in the `bgg_data` text column, so no additional API calls are needed for backfill (see below).

## Bucketing (render helper, no DB/LLM)

Pure function, same pattern as `answer_confidence/1`:

| Weight range | Label |
|---|---|
| < 1.5 | Light |
| 1.5–2.5 | Medium-Light |
| 2.5–3.5 | Medium |
| 3.5–4.5 | Medium-Heavy |
| ≥ 4.5 | Heavy |

## Expansion aggregation

Games and expansions are both rows in the `games` table (linked M2M via `game_expansion_links`), each with their own `bgg_id` and now their own `weight`. When one or more expansions are currently selected (existing selection state used elsewhere for expansion-aware answers), the displayed badge uses the **max weight** among the base game + selected expansions — matches the intuition "expansions only add complexity, never reduce it."

## No-data fallback

If `weight` is `nil` (BGG has no community rating yet, e.g. new/low-vote games), the badge is hidden entirely. No placeholder, no "N/A" — consistent with the "Did you know?" card's no-fallback precedent.

## Backfill for existing games

Games imported before this feature don't have `weight` set, but their raw BGG XML is already cached in `bgg_data`. A one-time Oban worker:

- Iterates existing games where `weight IS NULL` and `bgg_data IS NOT NULL`.
- Reparses the cached XML for `averageweight` only (no BGG API call).
- Sets `weight`, skips rows that already have it set (idempotent, safe to re-run/retry).

## Display

Badge rendered on the game show page (`game_live/show.ex`), placed near the game title, alongside/near the existing verdict-stamp region. Plain label + optional icon, computed at render time from stored `weight` — no per-request worker or LLM cost.

## Testing

- Unit test the bucketing helper across boundary values.
- Unit test `parse_game_info/1` correctly extracts `averageweight` from sample BGG XML fixtures.
- Test max-aggregation logic across base + multiple expansions, including nil-weight expansions (should not incorrectly zero-out the max).
- Test backfill worker: skips already-set rows, sets weight from cached XML, no-op on missing `bgg_data`.
