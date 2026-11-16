# Data Flows

## Ask a Question

```
GameLive.Show handle_event("ask")
  → Games.log_question/1 (insert QuestionLog with answer="Thinking...", gets real ID)
  → Oban.insert(AskWorker) (enqueue background job with question_log_id)
  → LiveView: append user_msg(id) + thinking_msg(id, pending) to conversation
  → pending_count incremented (max 5 concurrent, input disabled at limit)

AskWorker.perform (background, Oban queue)
  → Security.prompt_injection?/1 → blocked path if it trips
  → LLM.ask/5
    → Embed.embed/1 (embed question once; reused below)
    → Games.find_similar_question_in_pool/3 (embedding check, COMMUNITY-only)
      → HIT: return cached answer ("pool" provider). Private Q&A is never served.
    → MISS: retrieve_chunks_for_games/3 (vector search, reuses the embedding)
            → LLM.do_request (json_object response_format) → JSON answer object
  → Games.log_question_update/2 (save answer, citation, provider, embedding, etc.)
  → unless refused: TagQuestionWorker.enqueue (categorize)
  → PubSub.broadcast({:ask_complete, %{question_log_id, ...}})

Note: there is no separate FAQ cache layer. FAQ was collapsed onto QuestionLog
(`visibility = "community"` + optional admin-curated `canonical_question`/
`canonical_answer`). `RuleMaven.Faq` is now only community counts/stats.

GameLive.Show handle_info({:ask_complete})
  → get_question_log_by_id/1 (read only this one answer from DB)
  → Targeted in-place update: match messages by question_log_id, replace content
  → pending_count decremented
  → No full conversation rebuild — no DOM clobber, no index shift
  → Refused answers skip followup suggestions and the community pool.
```

Key files:
- `lib/rule_maven_web/live/game_live/show.ex` — LiveView handler: `handle_event("ask", ...)`
- `lib/rule_maven/games.ex` — `log_question/1`, `retrieve_chunks_for_games/3` (accepts `:embedding`), `log_question_update/2`, `find_similar_question_in_pool/3` (community-only)
- `lib/rule_maven/llm.ex` — `ask/5` (pool check → retrieval + LLM call, JSON output)
- `lib/rule_maven/embed.ex` — `embed/1` (768-dim, dimension-guarded)
- `lib/rule_maven/workers/ask_worker.ex` — background ask, sets parent_question_id on followups

## Save Rulebook

```
GameLive.Form (save_game/4)
  → Games.create_game/1 OR Games.update_game/2
  → Games.create_document/1 (attrs with full_text)
    → (has pdf_path) PdfCompressWorker: downsample PDF images to 300 dpi in place, update file_size
    → insert Document
    → chunk_document/1 (split text, insert Chunks)
    → Oban.insert(EmbedChunksWorker) (embed chunks in background)
    → Oban.insert(CheatSheetWorker) (generate cheatsheet, skipped in test)
  → push_navigate to edit page
```

When user navigates to game show page later:
```
GameLive.Show handle_params
  → if sources exist, send self {:refresh_suggestions, game, sources, already_asked}
  → handle_info calls LLM.suggest_questions/3
  → assigns @suggestions, renders suggestion buttons
```

Key files:
- `lib/rule_maven_web/live/game_live/form.ex` — `save_game/4` (new + existing games)
- `lib/rule_maven/games.ex` — `create_game/1`, `update_game/2`, `create_document/1`, `chunk_document/1`
- `lib/rule_maven/workers/embed_chunks_worker.ex` — async embedding
- `lib/rule_maven/workers/cheat_sheet_worker.ex` — async cheatsheet generation
- `lib/rule_maven_web/live/game_live/show.ex` — `handle_params` triggers suggestions

## Community Promotion (nightly cron)

There is no clustering-into-candidates job and no FaqCandidate/FaqEntry tables —
those were collapsed. The only nightly job is direct promotion to the community
pool.

```
DirectPromotionWorker.perform/1 (Oban cron, "0 4 * * *", :clustering queue)
  → fetch upvoted (feedback="up"), non-refused, non-community, embedded questions
  → group per game, cluster by embedding cosine similarity
    (cluster_similarity_threshold setting, default 0.85)
  → cluster asked+upvoted by ≥3 DISTINCT users
    → promote best representative (prefer canonical, then newest)
      → set visibility="community"
      → EmbedQuestionWorker.enqueue (re-embed for pool matching)
```

Key files:
- `lib/rule_maven/workers/direct_promotion_worker.ex` — clustering + promotion
- `config/config.exs` — Oban crontab
- `lib/rule_maven_web/live/admin_live/questions.ex` — admin review of community Q&A

## Followup Chain Persistence

```
LLM.ask/5 returns followup: true (LLM detected followup based on recent context)
  → AskWorker.perform/1
    → Games.find_parent_question_id/3 (find most recent root question by same user)
    → Games.log_question_update/2 (set parent_question_id on followup question)
  → GameLive.Show.handle_info(:ask_complete)
    → Targeted update by question_log_id (followup flag set on user message)
    → On next page load: handle_params → build_conversation/1 includes followup indentation
```

Key files:
- `lib/rule_maven/games.ex` — `find_parent_question_id/3`, `grouped_questions/1`
- `lib/rule_maven/workers/ask_worker.ex` — sets parent_question_id
- `lib/rule_maven_web/live/game_live/show.ex` — `build_conversation/1`, followup indentation

## Thread Consolidation (Admin)

```
AdminLive.Threads ("Review Threads")
  → Games.all_question_threads/0 (list all root questions with followups)
  → Admin "prepare_merge" → build_consolidated_answer/2 (combine root + followup answers)
  → Admin edits Q&A → "merge_thread"
    → update root QuestionLog: visibility="community",
      canonical_question + canonical_answer (no separate FAQ table)
    → EmbedQuestionWorker.enqueue (re-embed canonical question)
```

Key files:
- `lib/rule_maven/games.ex` — `question_threads/1`, `all_question_threads/0`
- `lib/rule_maven_web/live/admin_live/threads.ex` — thread UI, merge form, `build_consolidated_answer/2`

## Prepare Pipeline (Readiness)

```
Prepare page "Prepare"/"Run remaining" → Readiness.start_auto/2 → ReadinessWorker
  → Readiness.drive/1 → next_action/2 (pure):
      bgg → source → extract → review (PAUSE "needs_review") → cleanup → embed → :done
  → each step's worker finishes → Jobs.finish_run/3 → Readiness.advance/1 → worker again
"resume" checks next_action/1 first: a still-holding {:pause, reason} flashes the blocker, no re-arm
```

Review gate = `Games.review_block_count/1`: unreviewed LOW-CONFIDENCE pages only.
Cleanup-critic `cleanup_defects` flag pages in the UI (`page_needs_review?/1`) but never
gate review — cleanup runs AFTER review, so they deadlocked the pipeline.
Edit page "Mark reviewed" → `Games.mark_page_reviewed/2` sets Page `reviewed` (lifts the
low-confidence block) + clears that page's `cleanup_defects`, then `Readiness.advance/1`.
Only a re-extract resets `reviewed` — NEVER cleanup: the advance runs cleanup next, and a
reset there re-closed the review gate behind the pipeline (the Black Plague loop).
Edit page review banner lists flagged pages as jump chips ("goto_source_page"; ⚠ = blocks Ready);
Mark reviewed advances to the next flagged page.

Chunking: `Games.chunk_document/1` → `carry_scenario_headings/1` adds "(Continues: QUEST 0: …)" under
`[Page N]` for chunks continuing a scenario (one page past the heading; decorated two-line headings joined; ToC lines ignored). Prepare embed step "⟳ Re-chunk" applies it to embedded docs. Re-chunk
(re-embed) a doc to apply it to existing games.

## Remote Prepare (Claude-authored, any environment)

```
Claude transcribes page PNGs → pages JSON; authors enrichments+answers JSON
  → POST /api/admin/games/:token/documents   (ManualImport.import/2; pdf_url → RulebookDownloader.fetch_validated_pdf)
      → create_document → chunks + EmbedChunksWorker (server runs it)
  → POST /api/admin/games/:token/content     (Enrichments.import/2 + Answers.import/3, owner = token user)
  → GET  /api/admin/games/:token             (Readiness.state — wait for embed done)
  → POST /api/admin/games/:token/publish     (Readiness.approve_publish/2)
```
Auth: `ApiAuth` → `Users.get_api_user/1`. Every mutation is `Audit.log`ged (`api.*`). Same code path as the `mix rule_maven.import_*` tasks.

## Wrong-answer review (Claude-operated)

```
player 🚩 report (QuestionFlag) / 👎 (questions_log.feedback="down")
  → Corrections.queue/1  (mix rule_maven.corrections list | GET /api/admin/corrections)
  → Claude checks the answer against the rulebook transcription
  → correct: Answers.ground_citations/3 → log_question_update → force_publish_question (pooled)
             → resolve_flags → Audit "answer.manual_correction"
    uphold:  resolve_flags → Audit "answer.review_upheld"
  (mix rule_maven.corrections apply USER FILE | POST /api/admin/corrections)
```

## Ask pipeline — unsupported-negation recheck

After the refusal escalations, `LLM.maybe_recheck_unsupported_negation/6`: an
answer asserting do not/cannot/instead/skip/never with NO restrictive word in
any cited quote gets one escalate-model re-ask (`negation_recheck_nudge`),
re-grounded; a refusal/blank recheck keeps the original.

## Symbol key (rulebook icons)

```
transcription writes icons as neutral bracket tokens ("[purple hammer symbol]")
  → key per game: game_symbols (token → book name/meaning/aliases/page + optional icon)
     Claude: tmp/rebuild/SYMBOLS.md → Enrichments "symbols" (image_base64 | local image_path)
     in-app: Readiness :symbols → SymbolKeyWorker (candidates extracted in code; none → mark_none, no LLM)
     every token must occur in the book text (Symbols.tokens_in_text/2)
  → ask: LLM.build_context_block appends Symbols.prompt_block(base + expansions) inside the cached prefix
  → Symbols tool (base + toggled expansions); icons via SymbolController only while
     :symbol_images flag on AND per-game toggle on (Prepare page) AND game Ready/admin
  → answers + citation quotes (Q&A, Community): SymbolMarkup.decorate swaps known tokens in rendered
     HTML text for icon + name chips (icons off → token text keeps a name tooltip); copy/share text stays plain
```
