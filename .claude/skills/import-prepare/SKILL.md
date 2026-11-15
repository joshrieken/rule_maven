---
name: import-prepare
description: End-to-end import + Prepare of a board-game rulebook PDF (plus FAQ/errata) into Rule Maven with Claude subagents doing ALL the LLM work — transcription, enrichments, answers, symbol key, answer-pool pre-fill — then publish to Ready. Use when the user gives a rulebook PDF or names a game and says "import", "prepare", "add this game", "make it Ready", "rebuild", or "pre-fill".
---

# Import + Prepare a game (Claude-authored)

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

**Guides** (give subagents the PATH, never paste): `references/TRANSCRIBE.md`,
`references/AUTHOR.md`, `references/SYMBOLS.md`, `references/PREFILL.md`.
**Scripts**: `scripts/tokens.py`, `scripts/check_content.py`, `scripts/merge_prefill.py`,
`scripts/import_prefill.sh`, `scripts/publish.exs`.
(all under `.claude/skills/import-prepare/`; run python with `python3 -I`)

**Every subagent prompt must say:** write output files with Bash (heredoc / python),
not the Write tool — background sessions guard the shared checkout and agents
otherwise strand files in /tmp. `tmp/` is gitignored data, not code.
Also: no mix, no DB, no commits; report counts + unsure items only, never paste content.
(zsh here has `noclobber`: overwrite with `>|`, not `>`.)

## 0. Preflight (5 min, inline)
- Dev server on :4000? `lsof -iTCP:4000 -sTCP:LISTEN`. Mix tasks run with Oban queues
  OFF and only insert jobs; never start a 2nd server / live-queue BEAM.
- `pdfinfo PDF` (title, pages, size); `pdftotext -f N -l N PDF -` on 4-6 pages:
  born-digital? appended FAQ/errata/back cover? 2-page spreads (landscape ~2x width)?
- Game row: `psql -d rule_maven_dev -c "select id,name,bgg_id,playable,year_published from games where name ilike '%x%' order by id"`
  — pick the edition by year/BGG id (base vs 2nd edition vs expansions). State:
  `select id,label,kind from documents where game_id=N` ·
  `select count(*) from questions_log where game_id=N` ·
  `select bgg_data is not null, theme_names->'sets' is not null as theme_sets from games where id=N` ·
  `select count(*) from game_expansion_links where base_game_id=N or expansion_id=N`.
  A non-null `theme_palette` is NOT enough: legacy single palettes (no `theme_names.sets`)
  need the 3-5 hand-picked sets of step 9. Zero links with BGG data present → step 9 relink.
  Non-empty docs/answers → ASK before `mix rule_maven.reset_prepared N --yes` (deletes Q&A AND PDFs; back up first).

## 1. Back up + split sources (inline)
- `cp PDF tmp/rebuild/backup/pdfs/<slug>_full.pdf`.
- One document per source kind (authority errata > faq > rulebook > scenario…,
  `Games.Document.kinds/0`). Appended FAQ → own doc, kind "faq":
  `pdfseparate full.pdf dir/p-%d.pdf` then `pdfunite` ranges into `<slug>.pdf` / `<slug>_faq.pdf`
  (ignore "recursive dicts" warnings).
- Page keys (printed, else sheet) must be unique ACROSS docs: unnumbered trailing
  pages of doc 2 collide with doc 1's low numbers → give them positional numbers.
- 2-page spreads: split each sheet into two pages with real printed numbers.

## 2. Icon glossary (inline; skip for icon-free books)
Render the book's iconography/reference page; write `tmp/rebuild/<slug>/GLOSSARY.md`:
look → exact token. Book labels the icon → token may carry the label (`[Move icon]`,
`[POISON icon]`); unlabeled → neutral look (`[purple hammer symbol]`). Number
families with digits (`[black triangle: 3]`). Tell agents: printed words stay words
(write both: `Move [Move icon] 3`); invented tokens must be reported.
Example: `tmp/rebuild/gh/GLOSSARY.md`.

## 3. Transcribe (parallel)
One general-purpose agent per ~9 dense pages / ~15 prose FAQ pages, ALL in one message.
Prompt: page range · PDF path · TRANSCRIBE.md + GLOSSARY.md paths · "skip the
symbol-key step" · born-digital tip: `pdftotext -f N -l N` draft for spelling, PNG
(150dpi, 300dpi crops) for structure/icons/card art · own scratch dir under
`tmp/rebuild/<slug>/scratch/<part>` · output `tmp/rebuild/<slug>/parts/<part>.json`
as `{"pages":[{sheet,printed,text}]}` · report invented tokens + unsure spots.
~2-6 min each. Hidden text layers (cropped card art, blank pages) — agents rightly omit.

## 4. Merge + normalize (inline — the step that needs YOU)
- `python3 -I scripts/tokens.py tmp/rebuild/<slug>/parts/*.json` → drift
  (`[small dot]`/`[small round dot]`, class icons as look vs name) and COLLISIONS
  (Gloomhaven: `[black circle: N]` was deck-type on p11 but standee numbers on p29;
  `[white circle: 2]` perk value vs scenario number; `[Heal icon]` used for hit points).
- Write `tmp/rebuild/<slug>/merge.py`: replacement map + per-page fixes → `out/<slug>.json`
  `{"label","kind","pdf","source_url":null,"pages"}`; assert every sheet present, text
  non-empty, unique page keys. Template: `tmp/rebuild/gh/merge.py`.
- Act on agents' unsure lists: trim anything INFERRED from art beyond printed labels
  (per-hex colour readings, partial-sheet numbers); verify any table read only from
  art with a 300dpi crop yourself.

## 5. Import pages
`mix rule_maven.import_pages GAME_ID tmp/rebuild/out/<slug>.json [tmp/rebuild/out/<slug>_faq.json]`
(lane "manual", no LLM cheat sheet). Embeddings run on the server (~minutes).

## 6. Author, symbols, pre-fill — ONE parallel wave (7 agents)
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
python3 -I scripts/check_content.py tmp/rebuild/content/<slug>.json tmp/rebuild/out/<slug>.json [..._faq.json]   # must print bad 0
mix rule_maven.import_content GAME_ID jrieken tmp/rebuild/content/<slug>.json
python3 -I -c "import json;s=json.load(open('tmp/rebuild/symbols/<slug>.json'))['symbols'];json.dump({'enrichments':{'symbols':s}},open('tmp/rebuild/symbols/<slug>.import.json','w'),ensure_ascii=False)"
mix rule_maven.import_content GAME_ID jrieken tmp/rebuild/symbols/<slug>.import.json
```
Filter mix output: `2>&1 | grep -E ": (enrichments|answers) |✗|\*\* \("`.
Read every ✗ line (citation rejects). Spot-check 1-2 crops with Read.

## 8. Pre-fill import
```
psql -At -d rule_maven_dev -c "select question from questions_log where game_id=N" >| tmp/rebuild/prefill/existing/<slug>.txt
python3 -I scripts/merge_prefill.py tmp/rebuild/prefill/<slug>.json tmp/rebuild/prefill/<slug>_{a,b,c,d}.json --content tmp/rebuild/content/<slug>.json --existing tmp/rebuild/prefill/existing/<slug>.txt
```
Resolve WARN near-dups by hand (keep one per ruling; also scan Jaccard ≥0.6 by eye —
Gloomhaven had 12 same-ruling pairs across agents), re-run `check_content.py --prefill`,
then `zsh scripts/import_prefill.sh <slug> GAME_ID [BASE_ID]`.

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
  dark enough for white text. Example: `tmp/rebuild/content/gloomhaven_theme.json`.

## 10. Publish + verify
`mix run --no-start scripts/publish.exs GAME_ID` → every `STEP … done`, `PLAYABLE true`.
```
select pooled, citation_valid, refused, audience, count(*), count(question_embedding) from questions_log where game_id=N group by 1,2,3,4;  -- all t,t,f,public
select operation, model, count(*) from llm_logs where game_id=N and inserted_at > now() - interval '3 hours' group by 1,2;  -- expect none
```

## 11. Wrap up
- Update memory `claude-authored-prepare` (game id, slug, counts, new gotchas) and
  THIS skill if a step changed. Commit skill changes.
- Report: docs/pages, suggested + prefill answers, symbols, rejects, things flagged
  for the user (card text read only from art, inferred items trimmed), PDF backup path.
- Scratch cleanup: delete with explicit absolute paths (`rm -r /abs/.../scratch/r1`);
  a `cd … && rm -rf rel/*` is blocked by the safety check.

## Expansions
Full enrichment set PLUS `expansion_delta` ({components, setup, rules}) — else the
app's LLM ExpansionDeltaWorker generates it. Import the expansion's answers onto the
BASE too with `"expansions": [exp_id]` (import_prefill.sh does this with BASE_ID).
Publish the expansion after its pages embed.

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
