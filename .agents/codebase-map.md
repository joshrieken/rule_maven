# Codebase Map

Progressive disclosure: scan this file to locate target modules. Load only what you need.

> **Auto-update:** After adding/removing/renaming a module, update this file.
> After changing a public function, update the Key Functions column.

## Shared platform library (`lib/lccz/`, synced — never edit here)

Copied from `hub/platform/elixir/lccz` by `hub/ops/sync-platform.sh`; edit and test it there. Rule Maven binds it:
`RuleMaven.Auth.Oidc` = `use Lccz.Oidc` (sign-in protocol, logout tokens), `RuleMavenWeb.SilentSignIn` = `use Lccz.SilentSignIn`,
`RuleMavenWeb.LiveSessions` → `Lccz.LiveSessions`, `RuleMaven.Changelog` → `Lccz.Changelog` (parser, audience rules),
`HubController` → `Lccz.Hub.serve/3`, `OidcController.backchannel/2` → `Lccz.Backchannel.serve/3`, `SignOn` groups → `Lccz.Groups.level/2`.

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
| `Users` | `users.ex` | — | User CRUD, auth helpers (password check refuses `password_hash ""` = sign-on account) | `get_user!/1`, `create_user/2`, `mark_version_seen/2`, `authenticate/2` |
| `Users.User` | `users/user.ex` | — | User schema (`seen_version`: last What's new release opened; `oidc_sub`: sign-on subject, unique; email optional when linked) | `sign_on_changeset/1`, `oidc_link_changeset/2`, `oidc_linked?/1` |
| `Auth.Oidc` | `auth/oidc.ex` | 300 | Single sign-on protocol (Assent OIDC): settings from `:oidc` env, PKCE+state+nonce, ID-token checks, end-session URL; discovery cached 1h; `silent: next` → `prompt=none` | `settings/0`, `enabled?/0`, `begin_sign_in/3`, `finish_sign_in/4`, `end_session_url/1`, `redirect_uri/0`, `session_days/0` (7) |
| `Auth.SignOn` | `auth/sign_on.ex` | 219 | Who a sign-on is: group check, find by `oidc_sub` / create (never by email/username), admin re-sync (super_admin untouched), linking | `sign_in/2`, `link/3`, `link_user/2`, `get_user_by_sub/1` |
| `Hub` | `hub.ex` | 151 | Low-Cal Calzone Zone hub summary for one person by `oidc_sub` (questions asked → level/active/headline/detail, version, unseen notes) + bearer check | `summary/2`, `hub_request?/1`, `levels/0` ([1, 10, 50]) |
| `Changelog` | `changelog.ex` | ~100 | App version (read from `VERSION` at compile time, `@external_resource` — never `Application.spec(:vsn)`, which goes stale on a VERSION-only bump) + CHANGELOG.md (parsed at compile time); per-reader filtering and the What's new mark | `releases/0`, `app_version/0`, `reader_releases/2`, `visible_releases/2`, `unseen?/3`, `unseen_for?/2`, `mark_seen/2`, `parse/1` |
| `Changelog.Parser` / `Changelog.Release` | `changelog/parser.ex`, `changelog/release.ex` | ~100 | Lenient CHANGELOG.md parser (`## vX.Y.Z (date)`, `### Everyone`/`### Admins`, wrapped bullets; skips `## Unreleased`) and its struct | `Parser.parse/1` |
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
| `UserLiveAuth` | `user_live_auth.ex` | — | (session helper) | LiveView session auth, assigns `current_user`; public `active_user/1` (suspension, force-logout, `SessionLifetime`); `get_session/1` adds `silent_sign_in` for a signed-out page load, `:app` redirects there on the dead render |

## Controllers (`lib/rule_maven_web/controllers/`)

| Module | File | Responsibility |
|--------|------|----------------|
| `SessionController` | `session_controller.ex` | Login page (sign-on button only while `Oidc.enabled?`), password auth |
| `AuthController` | `auth_controller.ex` | Logout (+ provider end-session redirect with the kept ID token), registration auto-login |
| `OidcController` | `oidc_controller.ex` | `POST /auth/oidc` (start, mode login/link), `GET /auth/oidc/silent` (prompt=none, quiet failure → /login, success → next), `GET /auth/oidc/callback`; ID token cookie `_rule_maven_oidc_id` |
| `SilentSignIn` | `silent_sign_in.ex` (in `rule_maven_web/`) | Silent sign-in trigger: `silent_path/1` (SSO on + GET navigation + no `rulemaven_sso_tried` cookie + not skipped path), `send_to_login/2` (require_login plugs), `put_tried_cookie/1` (10 min), `safe_next/1` (open-redirect guard) |
| `HubController` | `hub_controller.ex` | `GET /api/hub/summary?sub=` (bearer `RULEMAVEN_HUB_SECRET`; 401/400/404; no-store) |
| `Plugs.PasswordAuth` | `plugs/password_auth.ex` (in `rule_maven_web/`) | Router pipeline `:password_auth`: password routes refuse (flash → /login) while sign-on is on; `refusal/1` message |
| `SessionLifetime` | `session_lifetime.ex` (in `rule_maven_web/`) | `valid?/3`: sign-on sessions end at `sso_until` (7d); password sessions 30d grace once sign-on is on; `sso_until/1` |
| `AuthPlug` | `auth_plug.ex` | Session-based auth plug, assigns `current_user`; `require_admin/2` (signed out → `SilentSignIn.send_to_login/2`) |
| `ApiAuth` | `api_auth.ex` | Bearer-token plug for `/api/admin`: `Users.get_api_user/1` (super admin, unsuspended, 90-day `user_tokens` context "api"), else 401 JSON |
| `AdminApiController` | `admin_api_controller.ex` | Remote Prepare JSON API (Hashid tokens): `index` (?q=), `show` (readiness+docs), `create_document` (ManualImport; drops `pdf`, accepts `pdf_url`), `delete_document`, `create_content`, `publish` |
| `Plugs.Health` | `plugs/health.ex` (in `rule_maven_web/`) | `GET /health` before session/router/DB: loopback peer → `{"version":…}` (Docker healthcheck + `scripts/deploy.sh`), anyone else → `{"status":"ok"}` (version is signed-in only) |
| `Plugs.ClientIp` | `plugs/client_ip.ex` (in `rule_maven_web/`) | Real client `remote_ip` behind Cloudflare→Traefik: last XFF hop from a private peer; `cf-connecting-ip` only if that hop is a Cloudflare range. LoginThrottle depends on it |
| `CheatSheetController` | `cheat_sheet_controller.ex` | Serve cheatsheet HTML page + versioned pages |
| `ChangelogController` + `ChangelogHTML` | `changelog_controller.ex`, `changelog_html.ex`, `changelog_html/show.html.heex` | Signed-in-only `GET /changelog` "What's new" (signed out → /login): releases with notes for this reader (newest 3 open, older collapsed, admins' notes in a "For admins" block); marks seen before the layout renders so the header dot clears |

## Components (`lib/rule_maven_web/components/`)

| Module | File | Responsibility |
|--------|------|----------------|
| `CoreComponents` | `core_components.ex` | Shared UI: buttons, modals, forms, icons; `citation_pages/1`, `citation_chip/1` ("Rulebook p.4 · Official FAQ p.2" — names the source), `citation_cards` (optional `symbol_marks` → icon chips in quotes) |
| `Layouts` | `layouts.ex` + `layouts/` | Root layout, app shell; `version_link/1` (signed-in only; header "vX.Y.Z" → /changelog, red dot while `Changelog.unseen_for?/2`) |

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
| `test/rule_maven/changelog_test.exs` | CHANGELOG parser, admin filtering, unseen logic, mark_seen |
| `test/rule_maven_web/controllers/changelog_controller_test.exs` | What's new page renders, marks seen, header dot, admin-only notes |
| `test/rule_maven_web/controllers/oidc_controller_test.exs` | Sign-on: login page, start (PKCE/state/nonce, config redirect URI), callback refusals (state/nonce/PKCE/signature/exp/aud/iss/age), groups, create vs find, no email/username auto-link, admin sync, linking, sign-out, 7-day session |
| `test/rule_maven_web/controllers/password_auth_test.exs` | Password routes, registration, change password, admin create refuse while sign-on is on; work when off |
| `test/rule_maven/auth/sign_on_test.exs` | SignOn unit + `mix rule_maven.link_sso` |
| `test/rule_maven/hub_test.exs`, `test/rule_maven_web/controllers/hub_controller_test.exs` | Hub summary + endpoint |
| `test/rule_maven_web/controllers/silent_sign_in_test.exs` | Silent sign-in: trigger (navigation vs json/asset/websocket/public, cookie, SSO off), `safe_next` open-redirect cases, prompt=none start, quiet failures, success → next, sign-out cookie |
| `test/support/fake_oidc.ex` | Fake OIDC provider (Assent HTTP adapter): discovery, JWKS, token endpoint with PKCE check; `configure/1`, `issue_code/2` |
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
| Sign-in / single sign-on / account linking | `auth/oidc.ex` (protocol), `auth/sign_on.ex` (who), `oidc_controller.ex`, `silent_sign_in.ex` (silent sign-in trigger), `plugs/password_auth.ex`, `session_lifetime.ex`, `auth_controller.ex` (logout), `session_html/new.html.heex` (button), `settings_live.ex` (Link button), config/runtime.exs (`RULEMAVEN_OIDC_*`); flow in data-flows "Sign-in"; ops in overview "Single sign-on" |
| Page performance (queries/timings) | `test/perf/page_queries_test.exs` (excluded `:perf` tag: dead render vs connected mount per page on a copy of the dev DB — `MIX_TEST_PARTITION=_perfdata mix test --only perf test/perf`, setup in its moduledoc; `PERF_DETAIL=<path>` dumps each query); query ceilings next to the page tests (`game_live_query_budget_test.exs`). Game page coverage = `Coverage.game_snapshot/3` (4 queries); theme = `Games.effective_theme/1`, assigned once as `theme_style`/`has_game_palette` |
| Hub summary | `hub.ex`, `hub_controller.ex`, router `/api/hub`, prod.exs force_ssl exclude |
| App version / What's new / changelog | `changelog.ex` (+ `changelog/parser.ex`), `changelog_controller.ex`, `layouts.ex` `version_link/1` (in root.html.heex `.header-brand-group`), CSS `.header-version*` / `.changelog*` in app.css; content in `CHANGELOG.md`, version in `VERSION` |
