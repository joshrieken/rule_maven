---
name: import-prepare
description: End-to-end import + Prepare of a board-game rulebook PDF (plus FAQ/errata) into Rule Maven with Claude subagents doing ALL the LLM work — transcription, enrichments, answers, symbol key, answer-pool pre-fill — then publish to Ready. Use when the user gives a rulebook PDF or names a game and says "import", "prepare", "add this game", "make it Ready", "rebuild", or "pre-fill".
---

# Import + Prepare a game (Claude-authored)

**DEFINITION OF DONE (hard gate — never report an import finished without it):**
`python3 -I .claude/skills/import-prepare/scripts/audit.py GAME_ID` prints `0 GAP(s)`.
The audit diffs the game against every other Ready game across ALL game data
(every `games` column, every game-keyed table, everything hanging off its documents
and questions, column fill rates, per-game settings) plus invariants (playable,
≥3 theme sets, BGG weight, every catalog expansion linked, imported answers pooled/
valid/embedded, chunks embedded, symbols with icons, expansion delta). Each GAP is
either FIXED or added to `KNOWN_NA` in audit.py with a reason verified in code —
never waved off. Run it ALSO at preflight: it shows what the game already lacks.
Gloomhaven first shipped with a legacy single theme, no expansion links and no
BGG weight — all invisible to the step list, all caught by the audit.

Claude is the processor (HARD RULE, memory `claude-primary-processor`): never trigger
the app's paid LLM steps; never ask live questions to test. Only embeddings hit
OpenRouter (the import tasks queue them; the dev server runs them).
You orchestrate + validate + import; subagents read and write.
Reference run: Gloomhaven (game 349, 2026-11-14) — 82-page PDF, ~1.5h wall clock,
15 agents, 424 answers, 100 symbols.

**Data** lives in gitignored `tmp/rebuild/` (source of truth — never delete):
`backup/pdfs/<slug>*.pdf` · `out/<slug>.json` (+`_faq.json`) pages · `content/<slug>.json`
· `symbols/<slug>.json` + `symbols/<slug>/*.png` · `prefill/<slug>.json` · `<slug>/`
scratch (GLOSSARY.md, parts/, merge.py). Gloomhaven used `gh/`.

**Run every command from the repo root.** `scripts/X` / `templates/X` / `references/X`
below mean `.claude/skills/import-prepare/scripts/X` etc. — type the full path
(`mix run` resolves paths from the repo root; there is no top-level `scripts/`).
Answers/content are owned by an EXISTING username (default `jrieken`).

## NEVER (these spend the app's paid AI — Claude does that work instead)
- Never click Prepare-page step buttons, never switch a game's Prepare **Auto** on, never
  use the game form's "Refresh BGG" / catalog "Pull BGG": they enqueue LLM workers
  (BggEnrichWorker → ThemePaletteWorker, plus extract/cleanup/cheat-sheet/suggestion…
  workers). Use the mix tasks + `scripts/new_game.exs` instead.
- Never `import_pages` into a game that already has pooled answers: a new/changed
  document calls `Games.invalidate_pool/1`, which demotes the pool AND schedules
  PoolRebuildWorker (5 min later) to RE-ASK every pooled question with the paid
  model. To add/replace a source on a Ready game: re-prepare (see "Re-prepare").
- Never leave Prepare **auto-pilot** on: when an embed job finishes, `Readiness.advance`
  drives every missing enrichment through the paid workers. Preflight checks it.
- Never ask questions in the app to test; never run `mix rule_maven.eval`.
- Allowed spend: embeddings only (queued by import tasks; player asks are the players').

**Guides** (give subagents the PATH, never paste): `references/TRANSCRIBE.md`,
`references/AUTHOR.md`, `references/SYMBOLS.md`, `references/PREFILL.md`, `references/SOURCES.md`.
**Scripts**: `scripts/new_game.exs` (catalog row + BGG, no workers), `scripts/add_source.exs` (new doc on a Ready game, no paid rebuild), `scripts/audit.py` (completeness gate), `scripts/tokens.py`, `scripts/check_content.py`, `scripts/merge_prefill.py`,
`scripts/import_prefill.sh`, `scripts/publish.exs`.
**Templates**: `templates/merge.py`, `templates/GLOSSARY.example.md`,
`templates/theme.example.json`, `templates/expansion_delta.example.json`.
(all under `.claude/skills/import-prepare/`; run python with `python3 -I`)

**Every subagent prompt must say:** write output files with Bash (heredoc / python),
not the Write tool — background sessions guard the shared checkout and agents
otherwise strand files in /tmp. `tmp/` is gitignored data, not code.
Also: no mix, no DB, no commits; report counts + unsure items only, never paste content.
(zsh here has `noclobber`: overwrite with `>|`, not `>`.)

## 0. Preflight (5 min, inline)
- Fresh checkout: `mkdir -p tmp/rebuild/{backup/pdfs,out,content,symbols,prefill/existing}`.
- Auto-pilot must be off: `psql -d rule_maven_dev -At -c "select value from app_settings where key='readiness_auto_N'"`
  → anything but `on` is fine; if `on`: `mix run --no-start -e 'Mix.Tasks.RuleMaven.ResetPrepared.start_without_queues(); RuleMaven.Readiness.stop_auto(N)'`.
- `python3 -I .claude/skills/import-prepare/scripts/audit.py GAME_ID` first — every pre-existing GAP becomes a task.
- Dev server on :4000? `lsof -iTCP:4000 -sTCP:LISTEN`. Mix tasks run with Oban queues
  OFF and only insert jobs; never start a 2nd server / live-queue BEAM.
- `pdfinfo PDF` (title, pages, size); `pdftotext -f N -l N PDF -` on 4-6 pages:
  born-digital? appended FAQ/errata/back cover? 2-page spreads (landscape ~2x width)?
- Game not in the catalog (or unsure which row):
  `mix run --no-start .claude/skills/import-prepare/scripts/new_game.exs search "Name"` →
  `… new_game.exs add BGG_ID ["Name"] [--expansion-of BASE_GAME_ID]` (creates/reuses the
  row, fetches BGG directly, links). BGG data is a REQUIRED readiness step — a game
  without a bgg_id can never become playable.
- Game row: `psql -d rule_maven_dev -c "select id,name,bgg_id,playable,year_published from games where name ilike '%x%' order by id"`
  — pick the edition by year/BGG id (base vs 2nd edition vs expansions). State:
  `select id,label,kind from documents where game_id=N` ·
  `select count(*) from questions_log where game_id=N` ·
  `select bgg_data is not null, theme_names->'sets' is not null as theme_sets from games where id=N` ·
  `select count(*) from game_expansion_links where base_game_id=N or expansion_id=N`.
  A non-null `theme_palette` is NOT enough: legacy single palettes (no `theme_names.sets`)
  need the 3-5 hand-picked sets of step 9. Zero links with BGG data present → step 9 relink.
  Non-empty docs/answers → ASK before `mix rule_maven.reset_prepared N --yes` (deletes Q&A AND PDFs; back up first).

## 1a. Hunt for more sources (1 agent, parallel with step 1-3)
Every import: one general-purpose agent per game following `references/SOURCES.md`
(official FAQ / errata / living rules / designer rulings for the EXACT edition) →
`tmp/rebuild/sources/<slug>.json` + downloads in `tmp/rebuild/backup/pdfs/candidates/<slug>/`.
Give it the game, edition/year/publisher/BGG id and the current docs. Each `recommend:
import` candidate becomes its own document (kind faq/errata/reference; rulings → kind
"notes" or "faq" with the URL as source_url) transcribed in step 3 alongside the
rulebook. HTML rulings saved as .txt: transcribe as pages of ~400 words each,
printed=null, one ruling per paragraph with its URL. Skip `community` tier unless the
user agrees. Mention every candidate (imported or skipped) in the final report.

## 1. Back up + split sources (inline)
- `cp PDF tmp/rebuild/backup/pdfs/<slug>_full.pdf`.
- One document per source kind (authority errata > faq > rulebook > scenario…,
  `Games.Document.kinds/0`). Appended FAQ → own doc, kind "faq":
  `pdfseparate full.pdf dir/p-%d.pdf` then `pdfunite` ranges into `<slug>.pdf` / `<slug>_faq.pdf`
  (ignore "recursive dicts" warnings).
- Page keys (printed, else sheet) must be unique ACROSS docs: unnumbered trailing
  pages of doc 2 collide with doc 1's low numbers → give them positional numbers.
- 2-page spreads: split each sheet into two pages with real printed numbers.
- Spoiler material (campaign unlocks, locked classes, scenario/legacy reveals, a FAQ's
  spoiler section) → its OWN document with `"spoiler": true` in the pages JSON. Answers
  citing it render behind a warning and stay hidden until a player reveals them; Q&As
  written from it must NAME the card/scenario/item so they only match players who have it.
  Existing doc: `update documents set spoiler=true where id=N` (no re-import needed).

## 2. Icon glossary (inline; skip for icon-free books)
Render the book's iconography/reference page; write `tmp/rebuild/<slug>/GLOSSARY.md`:
look → exact token. Book labels the icon → token may carry the label (`[Move icon]`,
`[POISON icon]`); unlabeled → neutral look (`[purple hammer symbol]`). Number
families with digits (`[black triangle: 3]`). Tell agents: printed words stay words
(write both: `Move [Move icon] 3`); invented tokens must be reported.
Example: `templates/GLOSSARY.example.md`.

## 3. Transcribe (parallel)
One general-purpose agent per ~9 dense pages / ~15 prose FAQ pages, ALL in one message.
Prompt: page range · PDF path · TRANSCRIBE.md + GLOSSARY.md paths · "skip the
symbol-key step" · born-digital tip: `pdftotext -f N -l N` draft for spelling, PNG
(150dpi, 300dpi crops) for structure/icons/card art · own scratch dir under
`tmp/rebuild/<slug>/scratch/<part>` · output `tmp/rebuild/<slug>/parts/<part>.json`
as `{"pages":[{sheet,printed,text}]}` · report invented tokens + unsure spots.
~2-6 min each. Hidden text layers (cropped card art, blank pages) — agents rightly omit.

## 4. Merge + normalize (inline — the step that needs YOU)
- `python3 -I .claude/skills/import-prepare/scripts/tokens.py tmp/rebuild/<slug>/parts/*.json` → drift
  (`[small dot]`/`[small round dot]`, class icons as look vs name) and COLLISIONS
  (Gloomhaven: `[black circle: N]` was deck-type on p11 but standee numbers on p29;
  `[white circle: 2]` perk value vs scenario number; `[Heal icon]` used for hit points).
- `cp .claude/skills/import-prepare/templates/merge.py tmp/rebuild/<slug>/merge.py`, fill CONFIG (docs, parts, REPLACE
  map, PRINTED overrides, narrow page_fix collisions) and run it → `out/<slug>.json` per doc;
  it asserts every sheet present, text non-empty, page keys unique across docs.
- Act on agents' unsure lists: trim anything INFERRED from art beyond printed labels
  (per-hex colour readings, partial-sheet numbers); verify any table read only from
  art with a 300dpi crop yourself.

## 5. Import pages
`mix rule_maven.import_pages GAME_ID tmp/rebuild/out/<slug>.json [tmp/rebuild/out/<slug>_faq.json]`
(lane "manual", no LLM cheat sheet). Embeddings run on the server (~minutes).
Then IMMEDIATELY: `psql -d rule_maven_dev -c "select id,label,status from documents where game_id=N"` —
every doc must be `published`. Short / icon-heavy / low-prose text lands `pending_review`
(invisible to retrieval, coverage and citations). Publish it NOW, while the game has no
answers (approval invalidates the pool): `mix run --no-start -e 'Mix.Tasks.RuleMaven.ResetPrepared.start_without_queues(); RuleMaven.Games.approve_document(RuleMaven.Repo.get!(RuleMaven.Games.Document, DOC_ID))'`.

## 6. Author, symbols, pre-fill — ONE parallel wave (6-7 agents)
All need only the page files; launch together:
- **Content part 1** (AUTHOR.md): suggestions (6-7 × 5-6), categories, cheat_sheet,
  setup + one answer per suggestion → `content/<slug>_part1.json`; self-check with
  `check_content.py … --prefill` + exact-one-answer-per-suggestion. Name the
  questions players get wrong for this game.
- **Content part 2**: did_you_know, voices, first_player, common_mistakes, quiz,
  teach, score (`[]` for co-op is fine), turn → `content/<slug>_part2.json`.
- **Symbols** (SYMBOLS.md): give it the glossary, the icon page, the family tokens,
  the structural brackets to skip. `{n}` matches digits only — signed values need
  separate `+{n}` / `-{n}` tokens.
- **Pre-fill ×3-4** (PREFILL.md), disjoint page ranges (+ one agent for the FAQ),
  60-120 each → `prefill/<slug>_{a,b,c,d}.json`.
Give every agent ALL page files and say the FAQ outranks the rulebook.
~3-14 min each (symbols slowest).

## 7. Import content + symbols
```
python3 -I - <<'E'   # merge parts
import json; a=json.load(open("tmp/rebuild/content/<slug>_part1.json")); b=json.load(open("tmp/rebuild/content/<slug>_part2.json"))
a["enrichments"].update(b["enrichments"]); json.dump(a,open("tmp/rebuild/content/<slug>.json","w"),indent=1,ensure_ascii=False)
E
python3 -I .claude/skills/import-prepare/scripts/check_content.py tmp/rebuild/content/<slug>.json tmp/rebuild/out/<slug>.json [..._faq.json]   # must print bad 0
mix rule_maven.import_content GAME_ID jrieken tmp/rebuild/content/<slug>.json
python3 -I -c "import json;s=json.load(open('tmp/rebuild/symbols/<slug>.json'))['symbols'];json.dump({'enrichments':{'symbols':s}},open('tmp/rebuild/symbols/<slug>.import.json','w'),ensure_ascii=False)"
mix rule_maven.import_content GAME_ID jrieken tmp/rebuild/symbols/<slug>.import.json
```
Filter mix output: `2>&1 | grep -E ": (enrichments|answers) |✗|\*\* \("`.
Read every ✗ line (citation rejects). Spot-check 1-2 crops with Read.

## 8. Pre-fill import
```
psql -At -d rule_maven_dev -c "select question from questions_log where game_id=N" >| tmp/rebuild/prefill/existing/<slug>.txt
python3 -I .claude/skills/import-prepare/scripts/merge_prefill.py tmp/rebuild/prefill/<slug>.json tmp/rebuild/prefill/<slug>_{a,b,c,d}.json --content tmp/rebuild/content/<slug>.json --existing tmp/rebuild/prefill/existing/<slug>.txt
```
Resolve WARN near-dups by hand (keep one per ruling; also scan Jaccard ≥0.6 by eye —
Gloomhaven had 12 same-ruling pairs across agents), re-run `check_content.py --prefill`,
then `zsh .claude/skills/import-prepare/scripts/import_prefill.sh <slug> GAME_ID [BASE_ID]`.

## 9. Game metadata (check EVERY time — Gloomhaven shipped without both)
- Expansion links missing (BGG lists some but `game_expansion_links` empty — happens when
  the base was enriched before its expansion rows existed): free, DB-only:
  `mix run --no-start -e 'Mix.Tasks.RuleMaven.ResetPrepared.start_without_queues(); g = RuleMaven.Games.get_game!(N); IO.inspect RuleMaven.BGG.relink_from_cache(g)'`
  Linked expansions still need their own rulebook import to become Ready (see Expansions).
- No BGG data: `RuleMaven.BGG.enrich_game(game, force: true)` in `mix run --no-start`
  after `Mix.Tasks.RuleMaven.ResetPrepared.start_without_queues()` (BggEnrichWorker would queue the LLM ThemePaletteWorker).
- No theme SETS: download the BGG cover (`games.image_url`, `sips -Z 700`), Read it, hand-pick 3-4
  sets `{light:{accent,bg,surface,text}, dark:{…}, names:{light,dark}}` → `{"enrichments":{"theme":{"sets":[…]}}}`
  → import_content. Keep accents far apart (dedupe merges accent <45 RGB AND bg <30); light accents
  dark enough for white text. Example: `templates/theme.example.json`. BASE games only —
  the importer rejects a theme on an expansion (it inherits the base's).

## 10. Publish + verify + AUDIT (gate)
`mix run --no-start .claude/skills/import-prepare/scripts/publish.exs GAME_ID` → every `STEP … done`,
`PLAYABLE true` (on false it prints which steps are pending).
```
select pooled, citation_valid, refused, audience, count(*), count(question_embedding) from questions_log where game_id=N group by 1,2,3,4;  -- all t,t,f,public
select operation, model, count(*) from llm_logs where game_id=N and inserted_at > now() - interval '3 hours' group by 1,2;  -- expect none
```
Then `python3 -I .claude/skills/import-prepare/scripts/audit.py GAME_ID` → must print `0 GAP(s)`.
Legit exceptions are passed explicitly, e.g. an icon-free book:
`… audit.py GAME_ID --na "symbols with icons=book has no inline icons"`. Fix every GAP/FAIL;
`info  live ask refused` lines are coverage leads (add prefill answers when the book
covers them); `LOW` lines are worth a look but not blocking. If you discover a NEW
kind of miss the audit didn't flag, add a check for it to audit.py in the same session.

## 11. Wrap up
- Update memory `claude-authored-prepare` (game id, slug, counts, new gotchas) and
  THIS skill if a step changed. Commit skill changes.
- Report must include the audit result line. Report: docs/pages, suggested + prefill answers, symbols, rejects, things flagged
  for the user (card text read only from art, inferred items trimmed), PDF backup path.
- Scratch cleanup: delete with explicit absolute paths (`rm -r /abs/.../scratch/r1`);
  a `cd … && rm -rf rel/*` is blocked by the safety check.

## Expansions
- Row + link: `new_game.exs add EXP_BGG_ID --expansion-of BASE_ID` (or `BGG.relink_from_cache(base)`
  when the row exists). The BASE should be Ready first.
- Same pipeline on the expansion game (its own book), with these differences:
  full enrichment set PLUS `expansion_delta` (spec in references/AUTHOR.md "Expansion
  games", example `templates/expansion_delta.example.json`) — else the app's LLM
  ExpansionDeltaWorker would generate it; NO `theme` (rejected; inherited).
- Answers ON the expansion cite only its own pages. Combined base+expansion rulings →
  a second file `content/<base>_with_<exp>.json` = `{"expansions":[EXP_ID],"answers":[…]}`
  (pool hits when the expansion is toggled on). Check it against BOTH page files —
  `python3 -I .claude/skills/import-prepare/scripts/check_content.py content/<base>_with_<exp>.json out/<base>.json out/<exp>.json --prefill`
  (overlapping page numbers are fine; the importer finds the quoting book itself) — then
  `mix rule_maven.import_content BASE_ID jrieken tmp/rebuild/content/<base>_with_<exp>.json`. `import_prefill.sh SLUG EXP_ID BASE_ID` imports a prefill
  file both ways — only when its citations are all expansion pages.
- Audit both games: `audit.py EXP_ID` and `audit.py BASE_ID`.

## Add a source (FAQ/errata) to an already-Ready game — no re-prepare needed
1. Transcribe the new source (steps 2-4) → `tmp/rebuild/out/<slug>_<kind>.json` with page keys
   that don't collide with the existing docs (check `select label from documents where game_id=N`).
2. `mix run --no-start .claude/skills/import-prepare/scripts/add_source.exs GAME_ID tmp/rebuild/out/<slug>_<kind>.json`
   — disables pool rebuild for the window, imports, approves if pending_review, cancels the
   scheduled paid PoolRebuildWorker, re-pools the imported answers, restores the setting.
3. The new source may OVERRULE existing answers: one agent compares every existing answer
   (`psql -At -c "select id, question, answer from questions_log where game_id=N and llm_provider='manual'"`)
   against the new text and lists contradictions with replacement answer + citations; apply via
   `mix rule_maven.corrections` (see its moduledoc). Then a prefill agent adds Q&As for what the
   new source adds (dedupe with merge_prefill.py), import, audit.
4. If the new source SUPERSEDES an older doc of the same kind (e.g. FAQ 2022 vs FAQ v0.2),
   demote the old one so it can't tie on authority in the answer prompt (sources are ordered by
   kind): `mix run --no-start -e 'Mix.Tasks.RuleMaven.ResetPrepared.start_without_queues(); d = RuleMaven.Repo.get!(RuleMaven.Games.Document, DOC_ID); RuleMaven.Games.update_document(d, %{kind: "notes"})'`
   (no text change → no pool invalidation). Keep it rather than delete: existing answers cite it.
   Designer/forum rulings go in as kind "notes" too (below the rulebook) when any conflict with print.

## Re-prepare (replace a source / rebuild from scratch)
All source JSON lives in `tmp/rebuild/`, so a rebuild costs only embeddings:
1. `cp` any new PDF to `backup/pdfs/`; transcribe the new source (step 3-4).
2. `mix rule_maven.reset_prepared GAME_ID --yes` (deletes Q&A + docs + PDFs from uploads;
   keeps game row, BGG, theme, links). With no pooled answers left, PoolRebuildWorker no-ops.
3. Re-run steps 5-8 from the saved files (`out/`, `content/`, `symbols/`, `prefill/`),
   re-checking citations against the new pages; then publish + audit.
- **Re-preparing an EXPANSION strands the base's combined rows** (invalidate marks base rows
  whose expansion set contains it stale; re-import skips them as already answered).
  So re-prepare BASE and EXPANSION together: `reset_prepared BASE EXP --yes`, rebuild base,
  then expansion, then re-import the `<base>_with_<exp>` files; audit both.

## Remote / prod path
Same over HTTP: `mix rule_maven.api_token jrieken` (90-day bearer; scratchpad only,
never the repo) → `GET /api/admin/games?q=` · `POST /api/admin/games/:token/documents`
(pages JSON + optional `pdf_url`) · `POST …/content` · `GET …/:token` (wait embed) ·
`POST …/publish`. API strips `image_path` — send symbol crops as `image_base64`.

## Gotchas
- Vision readers NAME glyphs instead of copying them → glossary + token rules always.
- Agents pad answers with diagram inferences → trim to printed text.
- Card text printed only on art → `[Card illustration: …]`; flag to user; never a general rule.
- Empty enrichment from the APP's workers = Pending forever + re-bill; manual `[]` score is fine.
- Wrong answers later: `mix rule_maven.corrections list|apply`.
