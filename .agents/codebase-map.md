# Codebase Map

Progressive disclosure: scan this file to locate target modules. Load only what you need.

> **Auto-update:** After adding/removing/renaming a module, update this file.
> After changing a public function, update the Key Functions column.

## Context Modules (business logic — `lib/rule_maven/`)

| Module | File | Lines | Responsibility | Key Functions |
|--------|------|-------|----------------|---------------|
| `Games` | `games.ex` | 759 | Game/Document CRUD, questions, followup chains, chunk retrieval, community pool | `get_game!/1`, `create_game/1`, `create_document/1`, `grouped_questions/1`, `find_parent_question_id/3`, `community_questions/2`, `find_similar_question_in_pool/2`, `question_threads/1`, `retrieve_chunks/3`, `chunk_document/1` |
| `LLM` | `llm.ex` | 513 | LLM API calls (multi-provider), chat, question generation, pool/FAQ cache | `ask/4`, `chat/3`, `suggest_questions/3`, `provider/0`, `model/0`, `stats/1` |
| `LLM.Log` | `llm/log.ex` | — | LLM request/response logging | `log_llm/4` |
| `LLMProxy` | `llm_proxy.ex` | 33 | Routes LLM/embed calls through proxy when `llm_proxy_url` DB setting is configured | `chat_url/0`, `embed_url/0`, `enabled?/0` |
| `CheatSheet` | `cheat_sheet.ex` | 711 | Cheatsheet generation (async Oban), versions, HTML wrapping | `save_version/3`, `generate_async/5`, `generate_content/3`, `status/1`, `wrap_html_for_serve/2` |
| `CheatSheet.CheatSheetVersion` | `cheat_sheet/cheat_sheet_version.ex` | — | Schema for stored cheatsheet versions | — |
| `Faq` | `faq.ex` | 269 | FAQ CRUD, candidate clustering, auto-approval, thread consolidation | `create_faq/1`, `approve_faq/2`, `upsert_candidate/1`, `approve_candidate/2`, `consolidate_thread/3`, `build_consolidated_answer/2` |
| `Faq.FaqEntry` | `faq/faq_entry.ex` | — | Schema for published FAQ entries | — |
| `Faq.FaqCandidate` | `faq/faq_candidate.ex` | — | Schema for pending FAQ candidates | — |
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

## Schemas (data shape + changesets only — `lib/rule_maven/games/`)

| Schema | File | Responsibility |
|--------|------|----------------|
| `Game` | `games/game.ex` | Game name, BGG linkage, expansion relationships (`parent_id`) |
| `Document` | `games/document.ex` | Rulebook text (`full_text`), label, status, PDF/HTML paths |
| `Chunk` | `games/chunk.ex` | Text chunks with embeddings, linked to Document. `page_number` from PDF page. |
| `QuestionLog` | `games/question_log.ex` | Asked questions, answers, citations, pinned status, history chain, refused flag, cleaned_question |

## LiveViews (UI pages — `lib/rule_maven_web/live/`)

| Module | File | Lines | Route | Responsibility |
|--------|------|-------|-------|----------------|
| `GameLive.Index` | `game_live/index.ex` | 609 | `/` | Game list, search, delete |
| `GameLive.Show` | `game_live/show.ex` | 1459 | `/games/:id` | Ask questions, view answers, conversation UI (all threads, up to 5 concurrent), followup chains, community pool, search |
| `GameLive.Form` | `game_live/form.ex` | 1965 | `/games/new`, `/games/:id/edit` | Create/edit game, add rulebook (text/PDF/upload), suggested questions |
| `GameLive.Review` | `game_live/review.ex` | 243 | `/games/:id/review` | Review document chunks, approve/reject |
| `GameLive.Import` | `game_live/import.ex` | 328 | `/games/import` | Import games via BGG search |
| `GameLive.Refresh` | `game_live/refresh.ex` | 134 | `/games/refresh` | Refresh game metadata from BGG |
| `GameLive.Faq` | `game_live/faq.ex` | 106 | `/games/:id/faq` | Browse published FAQ entries per game, search |
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
| `CheatSheetController` | `cheat_sheet_controller.ex` | Serve cheatsheet HTML page + versioned pages |

## Components (`lib/rule_maven_web/components/`)

| Module | File | Responsibility |
|--------|------|----------------|
| `CoreComponents` | `core_components.ex` | Shared UI: buttons, modals, forms, icons |
| `Layouts` | `layouts.ex` + `layouts/` | Root layout, app shell |

## Workers — Oban (`lib/rule_maven/workers/`)

| Module | File | Responsibility |
|--------|------|----------------|
| `CheatSheetWorker` | `cheat_sheet_worker.ex` | Async cheatsheet generation (called after document save) |
| `EmbedChunksWorker` | `embed_chunks_worker.ex` | Embed document chunks (called after chunk creation) |
| `FaqClusterWorker` | `faq_cluster_worker.ex` | Cluster similar questions into FAQ candidates |
| `DirectPromotionWorker` | `direct_promotion_worker.ex` | Auto-promote exact-match Q&A to FAQ |
| `AskWorker` | `ask_worker.ex` | 98 | Background LLM ask via Oban, PubSub result broadcast |
| `FaqClusterJob` | `faq_cluster_job.ex` | Oban job struct for FAQ clustering |

## Test Files

| File | What It Tests |
|------|---------------|
| `test/rule_maven/games_test.exs` | Game CRUD, question logging |
| `test/rule_maven/games_document_test.exs` | Document auto-publish, quality checks |
| `test/rule_maven/games_chunk_test.exs` | Document chunking, chunk retrieval |
| `test/rule_maven/llm_test.exs` | LLM.ask response parsing, system prompts, mock injection |
| `test/rule_maven/faq_test.exs` | FAQ CRUD, candidate workflow |
| `test/rule_maven/faq_candidate_test.exs` | FAQ candidate clustering |
| `test/rule_maven/refusal_test.exs` | LLM refusal detection |
| `test/rule_maven_web/feature/flow_test.exs` | E2E: login, game list, auth visibility |
| `test/rule_maven_web/feature/smoke_test.exs` | Smoke: pages load, no crashes |
| `test/rule_maven_web/live/game_live/refresh_test.exs` | BGG refresh LiveView test |
| `test/support/data_case.ex` | DB setup helpers, fixtures |
| `test/support/feature_case.ex` | LiveView test helpers, auth |
| `test/support/fixtures/` | Factory functions for Game, User, Document |

## Quick Reference: Where to Find

| Task | Files to load |
|------|--------------|
| Add field to Game | `games/game.ex` (schema), `games.ex` (context), test |
| Change LLM prompt | `llm.ex` → `ask/4` or `chat/3` or `suggest_questions/3` |
| Fix conversation UI | `game_live/show.ex` (LiveView + template), `games.ex` (`grouped_questions/2`) |
| Fix rulebook upload | `game_live/form.ex` (LiveView), `games.ex` (`create_document/1`) |
| Add new background job | `workers/` (new file), `application.ex` (maybe), config |
| Change page layout | `components/layouts/` (root shell), `components/core_components.ex` (shared UI) |
| Add new LiveView page | `live/` (new file), `router.ex` (route), test |
| Debug FAQ cache | `llm.ex` (`ask/4`), `faq.ex` (`check_faq_cache/3`) |
| Debug question pool | `llm.ex` (`ask/4`), `games.ex` (`find_similar_question_in_pool/2`) |
| Debug followup chains | `games/question_log.ex` (schema), `games.ex` (`grouped_questions/1`, `find_parent_question_id/3`), `workers/ask_worker.ex` |
| Admin thread review | `admin_live/threads.ex`, `games.ex` (`question_threads/1`, `all_question_threads/0`), `faq.ex` (`consolidate_thread/3`) |
| FAQ page | `game_live/faq.ex`, `faq.ex` |
| Fix BGG import | `bgg.ex`, `game_live/import.ex` |
