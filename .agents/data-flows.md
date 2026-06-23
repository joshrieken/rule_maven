# Data Flows

## Ask a Question

```
GameLive.Show handle_event("ask")
  → Games.log_question/1 (insert QuestionLog with answer="Thinking...", gets real ID)
  → Oban.insert(AskWorker) (enqueue background job with question_log_id)
  → LiveView: append user_msg(id) + thinking_msg(id, pending) to conversation
  → pending_count incremented (max 5 concurrent, input disabled at limit)

AskWorker.perform (background, Oban queue)
  → Games.retrieve_chunks/3 (vector search on embeddings)
  → LLM.ask/4 (build prompt with chunks + game sources)
    → Games.find_similar_question_in_pool/2 (embedding check against community question pool)
      → HIT: return cached answer ("pool" provider)
    → Faq.check_faq_cache/3 (embedding check against FAQ entries, expansion-aware)
      → HIT: return cached answer ("faq" provider)
    → MISS: LLM.chat/3 → parse response → return cited answer with followup detection
  → Games.log_question_update/2 (save answer, citation, provider, etc.)
  → PubSub.broadcast({:ask_complete, %{question_log_id, ...}})

GameLive.Show handle_info({:ask_complete})
  → get_question_log_by_id/1 (read only this one answer from DB)
  → Targeted in-place update: match messages by question_log_id, replace content
  → pending_count decremented
  → No full conversation rebuild — no DOM clobber, no index shift
  → Refused answers skip followup suggestions and community pool.
  → Oban.insert(DirectPromotionWorker) (auto-promote exact-match to FAQ)
```

Key files:
- `lib/rule_maven_web/live/game_live/show.ex` — LiveView handler: `handle_event("ask", ...)`
- `lib/rule_maven/games.ex` — `log_question/1`, `retrieve_chunks/3`, `log_question_update/2`, `find_similar_question_in_pool/2`
- `lib/rule_maven/llm.ex` — `ask/4` (pool check → FAQ check → retrieval + LLM call)
- `lib/rule_maven/faq.ex` — `check_faq_cache/3` (private, embedding similarity, expansion-aware)
- `lib/rule_maven/workers/ask_worker.ex` — background ask, sets parent_question_id on followups

## Save Rulebook

```
GameLive.Form (save_game/4)
  → Games.create_game/1 OR Games.update_game/2
  → Games.create_document/1 (attrs with full_text)
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

## FAQ Cluster (periodic)

```
FaqClusterJob (Oban cron)
  → FaqClusterWorker.perform/1
    → group questions by embedding similarity
    → create FaqCandidate (canonical question + answer)
    → admin reviews in AdminLive
```

Key files:
- `lib/rule_maven/workers/faq_cluster_job.ex` — Oban job struct (cron config)
- `lib/rule_maven/workers/faq_cluster_worker.ex` — clustering logic
- `lib/rule_maven/faq.ex` — `upsert_candidate/1`, `approve_candidate/2`
- `lib/rule_maven_web/live/admin_live.ex` — admin review UI

## Auto-Promotion (after question answered)

```
DirectPromotionWorker.perform/1
  → check if same question+answer pair already exists as FAQ
  → if exact match or embedding similarity > threshold
    → auto-create FaqCandidate for admin approval
```

Key files:
- `lib/rule_maven/workers/direct_promotion_worker.ex` — promotion logic
- `lib/rule_maven/faq.ex` — `upsert_candidate/1`

## Followup Chain Persistence

```
LLM.ask/4 returns followup: true (LLM detected followup based on recent context)
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
AdminLive ("Review Threads" section)
  → Games.all_question_threads/0 (list all root questions with followups)
  → Admin selects thread → "Merge → FAQ"
    → Faq.build_consolidated_answer/2 (combine root + followup answers)
    → Admin edits Q&A, clicks "Publish to FAQ"
    → Faq.consolidate_thread/3 (create FaqEntry, publish)
```

Key files:
- `lib/rule_maven/games.ex` — `question_threads/1`, `all_question_threads/0`
- `lib/rule_maven/faq.ex` — `consolidate_thread/3`, `build_consolidated_answer/2`
- `lib/rule_maven_web/live/admin_live.ex` — thread UI, merge form
