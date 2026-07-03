# Task 3 Report: BGG expansion linking writes the join table (multi-parent)

**Status: COMPLETE** — branch `worktree-agent-a0f65367236383bf9`, commit `8e50819`.

## Implemented

1. **`BGG.link_expansions/2`** (lib/rule_maven/bgg.ex) rewritten per brief: splits links on `inbound`, links this game to EVERY matched inbound base and every matched outbound expansion via `Games.link_expansion/2` (idempotent, unmatched bgg_ids ignored). Signature unchanged — `relink_from_cache/1` and `fetch_and_enrich/1` callers untouched. Single-parent guard and all `parent_game_id` writes removed.
2. **form.ex call sites** (lib/rule_maven_web/live/game_live/form.ex):
   - Unlink handler (~line 844): `Games.update_game(exp, %{parent_game_id: nil})` → `Games.unlink_expansion(id, socket.assigns.game.id)` (the base is the editor's game, per handler context).
   - Edit-mount assigns (~line 322): `bases = Games.base_games_for(game)`; `parent_selected_id` = first base's id (single-select UI preserved); additional bases assigned to new `extra_bases` and rendered read-only ("Also linked to: …") under the parent picker. `extra_bases: []` added to mount defaults.
   - Expansion-pull prompt (~line 1631): `is_nil(game.parent_game_id)` → `not Games.expansion?(game.id)`.
   - Removed the `game[parent_game_id]` hidden input (the old write path through the save changeset). The picker now writes directly: `select_parent` calls `Games.link_expansion(game.id, base_id)`, `clear_parent` calls `Games.unlink_expansion(game.id, parent_selected_id)`. The picker only renders when `@game` is present, so `socket.assigns.game` is always set in these handlers.

## TDD evidence

- **RED**: created `test/rule_maven/bgg_link_expansions_test.exs` (verbatim from brief; no existing bgg test file). Run before impl: 0/3 passed — all failed with `base_ids_for == []` (old code wrote `parent_game_id`, skipped extra bases).
- **GREEN**: after rewriting `link_expansions/2`: 3/3 passed. Also ran `games_expansion_links_test.exs` + `game_form_kind_test.exs` after form.ex edits: 14/14 passed.
- **Full suite** (`MIX_TEST_PARTITION=t3 mix test`, isolated `rule_maven_testt3` DB):
  ```
  Finished in 67.8 seconds (3.0s async, 64.7s sync)
  Result: 504/521 passed (0/16 features, 504/505 tests)
  Failed: 16 features, 1 test
  ```
  Both failure groups are known/pre-existing: the 1 test is `prepare_render_test.exs:30`, the 16 features are Wallaby tests without a browser driver.

## Files changed

- `lib/rule_maven/bgg.ex` — link_expansions rewrite
- `lib/rule_maven_web/live/game_live/form.ex` — 4 call-site changes + extra_bases assign/render
- `test/rule_maven/bgg_link_expansions_test.exs` — new (3 tests)

## Final grep (`grep -rn parent_game_id lib/`)

```
lib/rule_maven/games.ex:449:        where: is_nil(g.parent_game_id),
lib/rule_maven/games.ex:484:        where: is_nil(g.parent_game_id)
lib/rule_maven/games.ex:528:        where: is_nil(g.parent_game_id)
lib/rule_maven/games/expansion_link.ex:5:  old single `games.parent_game_id` FK).
lib/rule_maven/games/game.ex:33:    belongs_to :parent_game, RuleMaven.Games.Game, foreign_key: :parent_game_id
lib/rule_maven/games/game.ex:34:    has_many :expansions, RuleMaven.Games.Game, foreign_key: :parent_game_id
lib/rule_maven/games/game.ex:56:      :parent_game_id,
```

Zero hits in bgg.ex or any LiveView. game.ex hits are the schema field/changeset (dropped by the later column-drop task). The three games.ex hits are pre-existing read-only `is_nil` filters in `search_catalog/2`, `list_collection/1`, `list_favorites/1` — not writes, not listed in this task's brief; flagging for the column-drop task, which must rewrite them to a NOT-EXISTS on `game_expansion_links` (or they break when the column drops).

## Self-review / concerns

- **Behavior change (intentional)**: parent selection/clearing now persists immediately on click instead of on form save, because the hidden-input write path had to go. `clear_parent` still has its `data-confirm`. Selecting a second base while one is linked *adds* a link (multi-parent model) rather than replacing — the UI then shows the first (name-sorted) base as "parent" with the rest under "Also linked to". Acceptable for Phase 1; a richer multi-base editor is presumably a later task.
- **`expansion?/1` extra query** in the bgg-enriched handler — one indexed EXISTS per refresh, negligible.
- The three `games.ex` `is_nil(parent_game_id)` reads (see above) — must be handled before the column drop.

## Fix Round (2026-07-03)

### Finding addressed
Important: stale picker assigns in `lib/rule_maven_web/live/game_live/form.ex`. `select_parent`/`clear_parent` persisted links immediately via `Games.link_expansion/2`/`unlink_expansion/2`, but overwrote `parent_selected_id`/`parent_selected_name`/`extra_bases` from the event params instead of re-deriving from the DB. Repro: game linked to base A (`parent_selected_id=A`, `extra_bases=[]`); selecting base B linked B but clobbered `parent_selected_id` to B, so A vanished from the rendered picker though still linked in the DB. `clear_parent` then only unlinked whichever base happened to be in `parent_selected_id`, stranding the other base linked-but-invisible.

### Fix
Extracted `defp assign_parent_state(socket, game)` (re-derives `bases = Games.base_games_for(game)`, `parent = List.first(bases)`, sets `parent_selected_id`/`parent_selected_name`/`extra_bases` exactly as mount did). Mount's inline block replaced with a call to this helper. `select_parent`, `clear_parent`, and `unlink_expansion` (the game's own base→expansion unlink, included per the fix mandate for consistency even though it doesn't touch this game's own parent assigns) now call `assign_parent_state(socket, socket.assigns.game)` after their DB write instead of hand-assigning from event params.

### TDD evidence

New test: `test/rule_maven_web/live/game_form_multi_parent_test.exs` — links expansion game to base A directly via `Games.link_expansion/2`, mounts the edit form, fires `select_parent` for base B, and asserts both bases are still linked in the DB (`Games.base_ids_for/1`) *and* both still render in the picker HTML; then fires `clear_parent` and asserts the remaining base stays linked and rendered.

RED (before fix, against merged-in code from cc11c93):
```
1) test linking a second base keeps the first base visible and linked (RuleMavenWeb.GameFormMultiParentTest)
   Assertion with =~ failed
   code:  assert html =~ "Base A"
   ...
   test/rule_maven_web/live/game_form_multi_parent_test.exs:67: (test)
Result: 0/1 passed
```
(failed on the post-`select_parent` assertion — "Base A" disappeared from the rendered HTML exactly as the finding describes, even though `Games.base_ids_for/1` still returned both ids).

GREEN (after fix):
```
MIX_TEST_PARTITION=t3fix MIX_ENV=test mix test test/rule_maven_web/live/game_form_multi_parent_test.exs test/rule_maven/bgg_link_expansions_test.exs
....
Finished in 1.6 seconds (1.5s async, 0.1s sync)
Result: 4 passed
```

Broader regression check (scoped, not full suite):
```
MIX_TEST_PARTITION=t3fix MIX_ENV=test mix test test/rule_maven_web/live/ test/rule_maven/bgg_link_expansions_test.exs test/rule_maven/games_expansion_links_test.exs
Result: 33 passed
```

### Commands run
```
git merge cc11c93 --no-edit
MIX_TEST_PARTITION=t3fix MIX_ENV=test mix ecto.create
MIX_TEST_PARTITION=t3fix MIX_ENV=test mix ecto.migrate
MIX_TEST_PARTITION=t3fix MIX_ENV=test mix test test/rule_maven_web/live/game_form_multi_parent_test.exs test/rule_maven/bgg_link_expansions_test.exs
MIX_TEST_PARTITION=t3fix MIX_ENV=test mix test test/rule_maven_web/live/ test/rule_maven/bgg_link_expansions_test.exs test/rule_maven/games_expansion_links_test.exs
```

### Files changed
- `lib/rule_maven_web/live/game_live/form.ex` — extracted `assign_parent_state/2`, mount + `select_parent` + `clear_parent` + `unlink_expansion` now call it instead of hand-assigning parent picker state
- `test/rule_maven_web/live/game_form_multi_parent_test.exs` — new (1 test, 3 assertion stages)
