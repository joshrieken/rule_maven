# Audit Fixes — 2026-07-02

Fixes from the five-agent full-app audit, priority order. Base: master 9ada776.

## Global Constraints

- TDD where feasible: failing test first, then fix. Feature/UI wiring may be verified by LiveViewTest.
- Follow existing code style; MDEx/HEEx conventions as found.
- All authorization via `Users.can?(user, :capability)` — never role-name strings.
- Every LLM prompt string lives in the Prompts registry (`RuleMaven.Prompts`), never hardcoded.
- Background/slow work: Oban for fire-and-forget, `start_async` for slow interactive; never block a LiveView.
- New/changed workers must report to the unified Jobs log (`Jobs.start_run/event/finish_run`).
- Tests: tee output to ./tmp/<name>.log; run only relevant test files per task (full suite at final review); delete logs when done.
- Do NOT run `mix test` for the whole suite mid-task. Compile with `mix compile --warnings-as-errors` before reporting DONE.
- Commit per logical change with conventional-commit subjects. Do not push.

## Task 1: Fix flash messages never rendering on connected LiveViews

**Problem (verified empirically):** `put_flash` in any LiveView sets the assign but nothing renders it. `RuleMavenWeb.Layouts.app/1` (lib/rule_maven_web/components/layouts.ex:11-33) contains `flash_group` but is dead code — `lib/rule_maven_web.ex:54-60` (`live_view` macro) sets no layout, and no LiveView renders `flash_group` itself. `root.html.heex:196` renders flash only at dead render; the root layout never re-renders after WebSocket connect. ~100+ put_flash call sites are invisible (rate-limit errors, permission denials, admin confirmations, "game removed", etc.). Controller-rendered pages (login) still show flash.

**Fix approach (decide based on what you find):** The clean fix is a live layout: make the `live_view` macro use `layout: {RuleMavenWeb.Layouts, :app}` and reconcile the duplicate app-shell/header markup between `Layouts.app` and `root.html.heex` so nothing renders twice (header/nav must appear exactly once). If `Layouts.app` duplicates the root shell substantially, the smaller-blast-radius alternative is: strip `Layouts.app` to essentially `flash_group` + `@inner_content` (keep root shell as-is) and wire it as the live layout. Pick whichever keeps every page pixel-identical except flash now appearing. Dead-render flash in root.html.heex must not double-show with the live flash_group — remove or gate the root one for live routes if needed (controller routes must keep working flash).

**Tests:** LiveViewTest — after an event that calls `put_flash` (e.g. GameLive.Show "ask" with a too-short question producing "Please ask a complete question."), assert the flash text appears in `render(view)`. Also a controller flash still renders (existing session/login tests may cover). Add a regression test file test/rule_maven_web/live/flash_rendering_test.exs.

**Files:** lib/rule_maven_web.ex, lib/rule_maven_web/components/layouts.ex, lib/rule_maven_web/components/layouts/root.html.heex, new test.

## Task 2: Thread user_id into LLM cost logging + close kill-switch gaps

**Problems:**
1. `lib/rule_maven/llm.ex:139` — `call_llm` calls `do_request(body, 1, operation: "ask", game_id: game.id)` without `user_id`, though `ask/5` receives it in opts. Same for normalize (`llm.ex:220-226`) and voice restyle (`lib/rule_maven/voices.ex:261-266`). Result: `llm_logs.user_id` nil for all user-driven spend; `user_cost_today/1` (llm.ex:1069) ~0; `user_daily_cost_cap` branch in `Games.check_rate_limit` (games.ex:1597) can never fire; `cost_by_user` blind.
2. Kill switch (`Settings.asks_disabled?`) gaps: (a) `resubmit_question` (lib/rule_maven_web/live/game_live/show.ex:1032-1046, retry/report-re-pull with skip_pool) checks only `check_rate_limit` — add the `asks_disabled?` guard mirroring the "ask" handler at show.ex:643; (b) `AskWorker.perform` (lib/rule_maven/workers/ask_worker.ex) never re-checks the switch, so queued/retried jobs spend after it flips — check at top of perform, finish the run gracefully (persist a friendly error answer, close Jobs run — mirror existing terminal branches); (c) `Voices.restyle` (voices.ex:221) is user-triggered fresh spend with no kill-switch gate and no user_id — gate it and attribute user_id (thread from callers; restyle callers live in show.ex voices flow and voices worker if any).

**Tests:** unit tests asserting llm_logs rows get user_id for ask/normalize/restyle paths (can stub HTTP via existing test patterns — look at test/ for existing LLM stubbing, e.g. Req.Test or bypass); kill-switch tests: asks_disabled → resubmit blocked, AskWorker.perform no-ops without LLM call, restyle blocked.

**Files:** lib/rule_maven/llm.ex, lib/rule_maven/voices.ex, lib/rule_maven/workers/ask_worker.ex, lib/rule_maven_web/live/game_live/show.ex, tests.

## Task 3: Add missing hot-path DB indexes

**Problems (from audit):**
- `questions_log.question_embedding` has no HNSW index — `find_similar_question_in_pool` seq-scans cosine distance on every ask. Chunks got HNSW in `20260620161900_add_hnsw_indexes.exs`; mirror its exact options (operator class `vector_cosine_ops`, same with/options) for questions_log.
- `chunks.document_id` unindexed (filtered in chunk_document, EmbedChunksWorker, Readiness.doc_embedded?).
- `questions_log.user_id` unindexed — `recent_question_count` filters user_id + inserted_at on every ask; make it a composite `[:user_id, :inserted_at]`.

**Fix:** one new migration; use `create index(..., concurrently: false)` matching project migration style (check recent migrations for @disable_ddl_transaction usage on the HNSW one and mirror it). `mix ecto.migrate` must succeed; `mix ecto.rollback` must too.

**Files:** new priv/repo/migrations/*.exs only.

## Task 4: games.ex data-integrity bundle

**Problems:**
1. **Same-user answer-cache staleness (HIGH):** `find_user_duplicate`/`find_user_similar` (games.ex:1844-1899) don't respect rulebook changes; `invalidate_pool` (games.ex:853) only demotes pooled/community rows; user-exact tier wins before pool check in LLM.ask (llm.ex:79). Fix: in `invalidate_pool`, also mark private user rows stale — simplest consistent mechanism: set `needs_review: false`? NO — decide: add a `stale` boolean or set `pool_eligible=false`? Read the schema first; the audit suggested stamping answers with a rulebook version OR flagging private rows in invalidate_pool so user-tier lookups exclude them. Prefer the smallest schema change: exclude rows with `inserted_at` older than the game's `content_updated_at`? Only if such a timestamp already exists. Otherwise add migration `questions_log.stale` default false, set true for game's rows in invalidate_pool, filter `stale == false` in both user-tier lookups. Keep pooled-row behavior unchanged.
2. **rechunk_all_documents skips invalidate_pool (games.ex:1100):** call invalidate_pool per affected game after re-chunk.
3. **chunk_document delete+insert not transactional (games.ex:2417):** wrap in Repo.transaction.
4. **delete_game bypasses delete_document cleanup (games.ex:250, delete_all_games games.ex:256):** iterate `delete_document/1` (as reset_preparation does) inside a transaction so files are removed, `cancel_document_jobs/1` runs, and generation-state Settings are cleaned.
5. **replace_page lost-update race (games.ex:2159 + reextract_page_worker.ex:978,1014):** `replace_page(doc, index, result)` rebuilds the whole pages array from a stale snapshot loaded before a 5-minute re-extract; clobbers concurrent `set_page_cleaned` writes. Fix: re-fetch the document inside `replace_page` (mirror `set_page_cleaned` at games.ex:1155) so the write applies to fresh state.

**Tests:** each item gets a test: invalidate_pool marks user rows stale + user-tier lookup excludes them; rechunk invalidates pool; delete_game removes files/cancels jobs (can assert delete_document called via file cleanup or job cancellation observable state); replace_page applied to re-fetched doc (simulate concurrent set_page_cleaned between load and replace).

**Files:** lib/rule_maven/games.ex, lib/rule_maven/workers/reextract_page_worker.ex (if signature changes), possibly one migration, tests.

## Task 5: Extraction ladder — failed reads must not vote

**Problem:** `vision_one` returns `""` on failure (lib/rule_maven/rulebook_downloader.ex:1197) and `Gate.agreement("","") == 1.0` (lib/rule_maven/extract/gate.ex:118 majority), so in `escalate_tiers` (rulebook_downloader.ex:962-984) a failed original read + failed T2a re-read settles the page as blank at confidence 0.8 — silent content loss.

**Fix:** exclude empty/failed reads from the majority vote in the escalation path. Both-empty is only valid agreement at T1's `assess` where both original readers genuinely saw the page. Distinguish "read failed" from "page is blank": have `vision_one` failure return an error marker (e.g. `{:error, reason}` or `nil`) rather than `""`, and make majority/escalation treat it as a non-vote (continue escalation or mark page failed for retry), OR filter `""` candidates out of majority when at least one non-empty read exists and require a non-empty quorum. Read the ladder code carefully and pick the minimal change that preserves current behavior for genuinely blank pages (both original T1 readers empty → still blank).

Secondary (audit L2, fix if cheap while in there): `Gate.majority` can be satisfied by the original disagreeing pair when T1 escalated on coverage/wordish rather than agreement — exclude the already-failed pair from settling T2a, or include coverage in the majority test.

**Tests:** unit tests on Gate/escalation: failed+failed ≠ blank consensus; blank+blank at T1 still blank; normal disagreement still escalates. Extraction tests likely exist under test/ — extend them.

**Files:** lib/rule_maven/extract/gate.ex, lib/rule_maven/rulebook_downloader.ex, tests.

## Task 6: form.ex — stop swallowing save/upload failures

**Problems:**
1. lib/rule_maven_web/live/game_live/form.ex:1254 — `{:noreply, saved} = save_game(socket, params)` but the error branch (form.ex:2089-2090 `update_game` → `{:error, changeset}`) still returns something that lets the handler ingest uploaded PDFs against unsaved state and navigate to /prepare with "Saved" flash. Fix: `save_game` returns tagged `{:ok, socket}` / `{:error, socket-with-changeset}`; only ingest uploads + navigate on success; on error re-render form with changeset errors.
2. form.ex:1244-1246 — failed PDF copies mapped `{:error,_} -> {:ok, :error}` then filtered — silent. Mirror the correct pattern at form.ex:1298-1308 (`process_uploads`): count failures, surface via flash/inline.

**Tests:** LiveViewTest — submit form with invalid update → stays on form, errors shown, no navigate; upload-copy failure surfaced (may need to stub File.cp failure — if too invasive, test the counting helper directly).

**Files:** lib/rule_maven_web/live/game_live/form.ex, tests.

## Task 7: Security trio

1. **Cheatsheet version IDOR (MED):** lib/rule_maven_web/controllers/cheat_sheet_controller.ex:18-26 `show_version/2` loads `CheatSheet.get_version(vid)` (unscoped Repo.get, lib/rule_maven/cheat_sheet.ex:63) without verifying it belongs to the token's game. Fix: scope the lookup — `get_version_for_game(game, vid)` joining version → document → game_id; 404 on mismatch (404 not 403, matching rulebook_controller's existence-hiding convention).
2. **Suspension not enforced on open non-admin sockets (MED):** lib/rule_maven_web/live/user_live_auth.ex:8-16 `:default` on_mount lacks the per-event reauth hook that `:admin` has (lines 31/47 `reauth_event`). Fix: attach an equivalent `attach_hook(:handle_event, ...)` in `:default` that re-checks `suspended?`/`session_valid?` (mirror admin implementation, but check suspension/session validity rather than admin capability) and halts with redirect/flash. Mind performance: this runs a DB fetch per event — mirror whatever the admin hook does (it already accepted that cost); if admin hook throttles/caches, copy that.
3. **Invite-code consumption race (LOW):** lib/rule_maven/invite_codes.ex:58-64 read-modify-write. Fix: atomic conditional `update_all` (`inc: [use_count: 1]`, `where: use_count < max_uses and active`), 0 rows = invalid.

**Tests:** controller test: version of game B via game A token → 404; LiveViewTest: suspend user mid-session, next event halts/redirects; invite-code concurrent-use test (two `use_code` calls on max_uses=1 code — second fails; a plain sequential test of the atomic guard is acceptable).

**Files:** cheat_sheet_controller.ex, cheat_sheet.ex, user_live_auth.ex, invite_codes.ex, tests.

## Task 8: runtime config hardening

1. config/runtime.exs:55 — `PHX_HOST` silently defaults to "example.com" in prod: raise with a helpful message (mirror DATABASE_URL's raise) when prod and unset.
2. config/runtime.exs:63-70 — missing `MAIL_API_KEY` in prod only warns and uses Local adapter: raise in prod unless `MAIL_ALLOW_LOCAL=true` escape hatch set (keep the warning in that case).
3. config/runtime.exs:37 — default POOL_SIZE 10 vs Oban concurrency total 16 (+web): raise default to 20; leave env override.

**Tests:** config files aren't unit-testable conventionally; verify `MIX_ENV=prod mix compile` isn't required — instead assert by reading. Manual verification: run `elixir -e` sanity or just ensure `mix compile` passes and document the three behaviors in commit message. (No test files needed; state this in report.)

**Files:** config/runtime.exs only.

## Task 9: medium quick-wins bundle

1. **Settings.put upsert (lib/rule_maven/settings.ex:18):** replace get-then-insert with `Repo.insert(..., on_conflict: {:replace, [:value, :updated_at]}, conflict_target: :key)` (check actual schema field names first).
2. **DownloadWorker unique coalescing (lib/rule_maven/workers/download_worker.ex:20):** `unique: [keys: [:game_id]]` drops distinct upload batches — include `:mode` (and batch discriminator if args carry one) in unique keys; verify no regression on the duplicate-protection the unique was for (same-mode double-click still coalesced).
3. **FAQ blur backdrop fixed/transform regression window (lib/rule_maven_web/live/game_live/game_theme.ex:38 + assets/css/app.css:977-993):** the `:has(.chat-layout)` opt-out at app.css:986 covers only Q&A; extend the opt-out to `:has(.blur-bg)` (use the actual class rendered by game_theme.ex — read it) or move the backdrop out of `.main-content`.
4. **CheatSheetWorker (lib/rule_maven/workers/cheat_sheet_worker.ex:15-28):** duplicates CheatSheetGenWorker and skips Jobs log. Investigate: if truly redundant (no distinct call sites), delete it and repoint any enqueuers to CheatSheetGenWorker; otherwise add Jobs start_run/event/finish_run.
5. **search_questions ILIKE wildcards (games.ex:1757):** escape `%`/`_`/`\` in user input before interpolating into the pattern.

**Tests:** Settings.put concurrent/upsert test; DownloadWorker uniqueness test (insert two jobs different modes → both enqueued; same mode+args → coalesced); search escape unit test. CSS change: no test, note in report. CheatSheetWorker: existing tests must pass; if deleting, grep all call sites first.

**Files:** settings.ex, download_worker.ex, app.css, game_theme.ex (read only), cheat_sheet_worker.ex (+callers), games.ex, tests.
