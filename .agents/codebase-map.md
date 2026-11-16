# Codebase Map

Progressive disclosure: scan this file to locate target modules. Load only what you need.

> **Auto-update:** After adding/removing/renaming a module, update this file.
> After changing a public function, update the Key Functions column.

## Context Modules (business logic — `lib/rule_maven/`)

| Module | File | Lines | Responsibility | Key Functions |
|--------|------|-------|----------------|---------------|
| `Games` | `games.ex` | 783 | Game/Document CRUD, questions, followup chains, chunk retrieval, community pool | `get_game!/1`, `create_game/1`, `create_document/1`, `log_question/1`, `log_question_update/2`, `grouped_questions/1`, `find_parent_question_id/3`, `community_questions/2`, `find_similar_question_in_pool/3`, `question_threads/1`, `retrieve_chunks/3`, `chunk_document/1`, `expansion_short_name/2` ("Base – X" → "X"), `answer_rulebook_checked?/1` (pool copies inherit the source row's status) |
| `LLM` | `llm.ex` | 513 | LLM API calls (multi-provider), chat, question generation, community pool cache | `ask/5`, `chat/3`, `suggest_questions/3`, `provider/0`, `model/0`, `stats/1` |
| `LLM.Log` | `llm/log.ex` | — | LLM request/response logging | `log_llm/4` |
| `LLMProxy` | `llm_proxy.ex` | 33 | Routes LLM/embed calls through proxy when `llm_proxy_url` DB setting is configured | `chat_url/0`, `embed_url/0`, `enabled?/0` |
| `CheatSheet` | `cheat_sheet.ex` | 711 | Cheatsheet generation (async Oban), versions, HTML wrapping | `save_version/3`, `generate_async/5`, `generate_content/3`, `status/1`, `wrap_html_for_serve/2` |
| `CheatSheet.CheatSheetVersion` | `cheat_sheet/cheat_sheet_version.ex` | — | Schema for stored cheatsheet versions | — |
| `Faq` | `faq.ex` | 24 | Rules Q&A (ex-Community Q&A) counts/stats. (FAQ collapsed onto QuestionLog `visibility`/`canonical_*`; FaqEntry/FaqCandidate tables removed.) | `community_count/1`, `stats/0` |
| `BGG` | `bgg.ex` | 368 | BoardGameGeek API integration, game search/enrich | `search/1`, `fetch_and_enrich/2` |
| `BggRefresher` | `bgg_refresher.ex` | — | GenServer for BGG refresh polling | `subscribe/1` |
| `Embed` | `embed.ex` | 83 | Text embedding via OpenRouter API | `embed/1` |
| `RulebookDownloader` | `rulebook_downloader.ex` | 328 | Auto-download/OCR rulebooks from URLs | `download/3` |
| `Settings` | `settings.ex` | 32 | KV settings store (ets-backed) | `get/1`, `put/2`, `delete/1` |
| `Settings.AppSetting` | `settings/app_setting.ex` | — | Schema for persisted settings | — |
| `Users` | `users.ex` | — | User CRUD, auth helpers | `get_user!/1`, `create_user/2` |
| `Users.User` | `users/user.ex` | — | User schema | — |
| `PostgresTypes` | `postgres_types.ex` | — | Custom Ecto types (e.g. `Ltree`) | — |
| `Repo` | `repo.ex` | 5 | Ecto repo module | — |
| `PdfCompress` | `pdf_compress.ex` | ~150 | Ghostscript downsample of stored PDFs to the 300 dpi render res (no auto-rotate; keep only if same page count + ≥10% smaller; atomic swap; skipped without gs). `file_hash` stays the original's (dedupe key) | `compress_document/1`, `compress_file/1`, `backfill/0` (prod: `bin/rule_maven rpc`) |
| `Release` | `release.ex` | 31 | Release-time tasks (no Mix in prod); run by `rel/overlays/bin/migrate` before every container start | `migrate/0`, `rollback/2` |
| `Flags` | `flags.ex` | ~195 | fun_with_flags facade (registry-validated) | `enabled?/2`, `seed_missing/0` (seed unsynced flags at defaults + admin bypass; used by `mix rule_maven.flags.sync` and prod deploy via `bin/rule_maven rpc`) |

## Schemas (data shape + changesets only — `lib/rule_maven/games/`)

| Schema | File | Responsibility |
|--------|------|----------------|
| `Game` | `games/game.ex` | Game name, BGG linkage, expansion relationships (`parent_id`) |
| `Document` | `games/document.ex` | Rulebook text (`full_text`), label, status, PDF/HTML paths |
| `Chunk` | `games/chunk.ex` | Text chunks with embeddings, linked to Document. `page_number` from PDF page. |
| `QuestionLog` | `games/question_log.ex` | Asked questions, answers, citations, pinned status, history chain, refused flag, cleaned_question; `rulebook_checked?/1` = llm_provider "manual" (Claude-imported/corrected → "📖 Rulebook-checked" badge, NOT a trust tier) ; `spoiler?/2` (cites a `documents.spoiler` source, index via `Games.spoiler_index/1`): Rules Q&A hides/masks them, chat gates the answer behind "Show answer" |

## LiveViews (UI pages — `lib/rule_maven_web/live/`)

| Module | File | Lines | Route | Responsibility |
|--------|------|-------|-------|----------------|
| `GameLive.Index` | `game_live/index.ex` | 609 | `/` | Game list, search, delete |
| `GameLive.Show` | `game_live/show.ex` | 1506 | `/games/:id` | Ask questions, view answers, conversation UI (all threads, up to 5 concurrent), followup chains, community pool, search |
| `GameLive.Form` | `game_live/form.ex` | 1965 | `/games/new`, `/games/:id/edit` | Create/edit game, add rulebook (text/PDF/upload), suggested questions |
| `GameLive.Review` | `game_live/review.ex` | 243 | `/games/:id/review` | Review document chunks, approve/reject |
| `GameLive.Import` | `game_live/import.ex` | 328 | `/games/import` | Import games via BGG search |
| `GameLive.Refresh` | `game_live/refresh.ex` | 134 | `/games/refresh` | Refresh game metadata from BGG |
| `GameLive.Faq` | `game_live/faq.ex` | 106 | `/games/:id/faq` | Browse community Q&A per game (incl. admin-curated `canonical_*`), search |
| `AdminLive.Index` | `admin_live/index.ex` | 82 | `/admin` | Admin dashboard with navigation tiles |
| `AdminLive.Db` | `admin_live/db.ex` | 540 | `/admin/db` | Browse/edit DB tables (CRUD), extended/table view |
| `AdminLive.Threads` | `admin_live/threads.ex` | 195 | `/admin/threads` | Review Q&A threads with followups, merge into FAQ |
| `AdminLive.Users` | `admin_live/users.ex` | 124 | `/admin/users` | User list with promote/demote role management |
| `AdminLive.Invites` | `admin_live/invites.ex` | 139 | `/admin/invites` | Generate and deactivate invite codes |
| `SettingsLive` | `settings_live.ex` | 605 | `/settings` | App settings: LLM keys, provider, models |
| `UserLiveAuth` | `user_live_auth.ex` | — | (session helper) | LiveView session auth, assigns `current_user` |

## Controllers (`lib/rule_maven_web/controllers/`)

| Module | File | Responsibility |
|--------|------|----------------|
| `SessionController` | `session_controller.ex` | Login form, password auth |
| `AuthController` | `auth_controller.ex` | Logout |
| `AuthPlug` | `auth_plug.ex` | Session-based auth plug, assigns `current_user` |
| `ApiAuth` | `api_auth.ex` | Bearer-token plug for `/api/admin`: `Users.get_api_user/1` (super admin, unsuspended, 90-day `user_tokens` context "api"), else 401 JSON |
| `AdminApiController` | `admin_api_controller.ex` | Remote Prepare JSON API (Hashid tokens): `index` (?q=), `show` (readiness+docs), `create_document` (ManualImport; drops `pdf`, accepts `pdf_url`), `delete_document`, `create_content`, `publish` |
| `Plugs.Health` | `plugs/health.ex` (in `rule_maven_web/`) | `GET /health` → `{"version":…}` before session/router/DB; Docker healthcheck + `scripts/deploy.sh` poll it |
| `Plugs.ClientIp` | `plugs/client_ip.ex` (in `rule_maven_web/`) | Real client `remote_ip` behind Cloudflare→Traefik: last XFF hop from a private peer; `cf-connecting-ip` only if that hop is a Cloudflare range. LoginThrottle depends on it |
| `CheatSheetController` | `cheat_sheet_controller.ex` | Serve cheatsheet HTML page + versioned pages |

## Components (`lib/rule_maven_web/components/`)

| Module | File | Responsibility |
|--------|------|----------------|
| `CoreComponents` | `core_components.ex` | Shared UI: buttons, modals, forms, icons; `citation_pages/1`, `citation_chip/1` ("Rulebook p.4 · Official FAQ p.2" — names the source), `citation_cards` (optional `symbol_marks` → icon chips in quotes) |
| `Layouts` | `layouts.ex` + `layouts/` | Root layout, app shell |

## Workers — Oban (`lib/rule_maven/workers/`)

| Module | File | Responsibility |
|--------|------|----------------|
| `PdfCompressWorker` | `pdf_compress_worker.ex` | Shrink a new source's PDF via `PdfCompress` (queue `reextract`); enqueued by `Games.insert_document` for any doc with `pdf_path`; Jobs kind `pdf_compress` |
| `AskWorker` | `ask_worker.ex` | Background LLM ask via Oban, PubSub result broadcast |
| `CheatSheetWorker` | `cheat_sheet_worker.ex` | Async cheatsheet generation (called after document save) |
| `EmbedChunksWorker` | `embed_chunks_worker.ex` | Embed document chunks (called after chunk creation) |
| `EmbedQuestionWorker` | `embed_question_worker.ex` | Re-embed a QuestionLog's canonical/question text |
| `TagQuestionWorker` | `tag_question_worker.ex` | Categorize an answered question |
| `DirectPromotionWorker` | `direct_promotion_worker.ex` | Nightly: cluster upvoted Q&A by embedding, promote to community pool |

## Test Files

| File | What It Tests |
|------|---------------|
| `test/rule_maven/games_test.exs` | Game CRUD, question logging |
| `test/rule_maven/games_document_test.exs` | Document auto-publish, quality checks |
| `test/rule_maven/games_chunk_test.exs` | Document chunking, chunk retrieval |
| `test/rule_maven/llm_test.exs` | LLM.ask response parsing, system prompts, mock injection |
| `test/rule_maven/faq_test.exs` | Rules Q&A counts/stats |
| `test/rule_maven_web/live/rules_qa_tabs_spoilers_test.exs` | Rules Q&A tabs (Prepared vs Player-asked) + spoiler hide/mask/reveal |
| `test/rule_maven/refusal_test.exs` | LLM refusal detection |
| `test/rule_maven_web/feature/flow_test.exs` | E2E: login, game list, auth visibility |
| `test/rule_maven_web/feature/smoke_test.exs` | Smoke: pages load, no crashes |
| `test/rule_maven_web/live/game_live/refresh_test.exs` | BGG refresh LiveView test |
| `test/support/data_case.ex` | DB setup helpers, fixtures |
| `test/support/feature_case.ex` | LiveView test helpers, auth |
| `test/support/fixtures/` | Factory functions for Game, User, Document |

## Ops scripts (repo root)

| File | Purpose |
|------|---------|
| `bin/prod` | Run a command against PROD from the Mac: rsync `tmp/rebuild/` up, `docker compose run --rm -T tools <cmd>` (mix/psql/python at the deployed commit, Oban off) |
| `bin/pull-prod` | Clone prod DB + uploads down into dev (`--db-only` skips uploads) |
| `bin/tools-entrypoint` | Tools container entrypoint: `mix deps.get --only prod` when `mix.lock` changed, then exec |
| `scripts/deploy.sh` | Server-side release-only deploy (backup → ff master → build → up → wait `/health` → seed flags) |
| `compose.yaml` / `Dockerfile` | Prod stack (app, pgvector db, `tools` profile service = Dockerfile `build` stage) |

## Quick Reference: Where to Find

| Task | Files to load |
|------|--------------|
| Add field to Game | `games/game.ex` (schema), `games.ex` (context), test |
| Change LLM prompt | `llm.ex` → `ask/5` or `chat/3` or `suggest_questions/3` |
| Fix conversation UI | `game_live/show.ex` (LiveView + template), `games.ex` (`grouped_questions/2`) |
| Expansion cues on Q&A | `game_live/show.ex`: composer chip (`data-testid=composer-expansions`), `ask_placeholder/2`, `suggestion_groups/4` (toggled expansions' `suggestions_<exp_id>` first, `.expansion-tag`); CSS `.composer-expansions` in priv/static/assets/css/app.css |
| Fix rulebook upload | `game_live/form.ex` (LiveView), `games.ex` (`create_document/1`) |
| Add new background job | `workers/` (new file), `application.ex` (maybe), config |
| Prepare pipeline stuck / Run remaining | `readiness.ex` (`next_action/1` pure decision, `drive/1` executes, `step_complete?/3`), `workers/readiness_worker.ex`, `game_live/prepare.ex` ("resume") |
| Import hand-authored enrichments / answers | `manual_import/enrichments.ex` (per-step validation mirroring the LLM parsers, same storage calls as the workers; `expansion_delta` step for expansions = ExpansionDeltaWorker's delta_* keys; `theme` step for base games = cover anchors → ThemePalette.build_sets → theme_palette/theme_names, like ThemePaletteWorker), `manual_import/answers.ex` (every citation must pass `Citations.valid_citations/2`, embeds question, `force_publish_question`; `import/4` `expansion_ids:` = answers for base+those expansions, cites any of their books, rows carry the set → pool hits when toggled; content JSON key `"expansions"`), `mix rule_maven.import_content GAME_ID USERNAME FILE.json` |
| Symbol key (icons) | `symbols.ex` (`list/1`, `list_for_games/1`, `replace/3`, `clear/1`, `done?/1`, `mark_none/2`, `candidate_tokens/1`, `tokens_in_text/2`, `token_regex/1` ({n} families), `prompt_block/1`, `store_image/3`, `images_enabled?/1` = :symbol_images flag AND per-game `set_images/3`), `symbols/symbol.ex` (game_symbols), `workers/symbol_key_worker.ex` (in-app LLM, readiness :symbols), Enrichments "symbols" step, `SymbolController.image` (gated `/symbols/:id/image`), ToolPanel `:symbols`, ToolHost `load_symbols/3` + `symbol_marks` assign; `rule_maven_web/symbol_markup.ex` (`marks/1`, `decorate/2`: tokens → icon chips in answer/citation HTML via show.ex + community.ex `render_markdown/2`; CSS `.sym-mark`); key appended in `LLM.build_context_block/3` |
| Wrong-answer review loop | `manual_import/corrections.ex` (`queue/1` = unresolved flags + unreviewed thumbs-down; `correct/3` grounds citations via `Answers.ground_citations/3`, pools, resolves flags, audits `answer.manual_correction`; `uphold/3`; `apply_all/2`), `mix rule_maven.corrections list [GAME_ID] \| apply USERNAME FILE.json`, API `GET/POST /api/admin/corrections` |
| Unsupported-negation recheck | `llm.ex` `maybe_recheck_unsupported_negation/6` + public `unsupported_negation?/1` (answer says do not/cannot/instead/skip, no quote is restrictive → one escalate-model recheck); prompt `negation_recheck_nudge` in prompts.ex |
| Remote Prepare (prod) via API | `curl -H "Authorization: Bearer $TOKEN"` against `/api/admin/games[/:token[/documents|/content|/publish]]` (router `:admin_api` scope; also `/api/admin/corrections`); mint with `mix rule_maven.api_token USERNAME [--revoke]` or `Users.create_api_token/1` in a release |
| Rebuild a game from hand-transcribed pages | `manual_import.ex` (`ManualImport.import/2`: JSON pages → create_document, lane "manual"), `mix rule_maven.import_pages GAME_ID FILE.json`, `mix rule_maven.reset_prepared GAME_ID --yes` (Q&A + reset_preparation; DELETES PDFs — back up). Both start Oban with queues OFF so the dev server runs the jobs |
| Page review flags | `games.ex` (`page_needs_review?/1` UI flag, `page_blocks_review?/1` pipeline gate, `mark_page_reviewed/2`), `games/document.ex` (Page `reviewed`), `game_live/form.ex` (`review_flag`, "mark_reviewed") |
| Change page layout | `components/layouts/` (root shell), `components/core_components.ex` (shared UI) |
| Add new LiveView page | `live/` (new file), `router.ex` (route), test |
| Rules Q&A page (`/games/:id/community`, ex-"Community Q&A") | `game_live/community.ex`: tabs verified/community/prepared (`QuestionLog.rulebook_checked?/1`)/unverified (=Player-asked); spoilers via `Games.spoiler_index/1` + `QuestionLog.spoiler?/2` → `spoiler_ids`, `hide_spoilers` (default on, omits), `revealed_spoilers` (masked card until Reveal); unrevealed spoilers never match search. Sub-bar pill there = "💬 Ask" (`sub_bar.ex header_pills`) |
| Debug community pool cache | `llm.ex` (`ask/5`), `games.ex` (`find_similar_question_in_pool/3`, community-only) |
| Debug LLM output parsing | `llm.ex` (`parse_response/1`, `decode_answer/1` — JSON `json_object`) |
| Debug followup chains | `games/question_log.ex` (schema), `games.ex` (`grouped_questions/1`, `find_parent_question_id/3`), `workers/ask_worker.ex` |
| Admin thread review | `admin_live/threads.ex` (`build_consolidated_answer/2`), `games.ex` (`question_threads/1`, `all_question_threads/0`) |
| FAQ page | `game_live/faq.ex`, `faq.ex` |
| Fix BGG import | `bgg.ex`, `game_live/import.ex` |
