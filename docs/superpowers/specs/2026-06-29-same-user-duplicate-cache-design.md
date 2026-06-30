# Same-user duplicate detection → serve from cache

**Date:** 2026-06-29
**Status:** Approved design

## Problem

A user asked the same question twice and got two separate Q&A rows (two LLM
calls) instead of a cache hit. Both answers were citation-grounded, so the
existing pool *should* have matched on the second ask — but didn't.

### Why it happens today

Cache serving runs entirely through `LLM.ask/5` → `Games.find_similar_question_in_pool/3`.
A second ask serves from cache only when:

1. `skip_pool == false` (regenerate/retry paths set it true and bypass cache),
2. the question embeds successfully, and
3. a prior row in the same game is within `pool_similarity_threshold` (cosine
   similarity, default **0.92**) AND is eligible: `pooled == true` or
   `visibility == "community"`, `refused == false`, `needs_review == false`.

The lookup deliberately does **not** filter by user — pooled answers are
rulebook-derived, so any asker may be served.

Two leaks let identical asks split into two rows:

- **Ephemeral in-conversation guard** (`show.ex:629`) blocks a re-ask only when
  the exact text is already in `socket.assigns.conversation`. That assign is
  **thread-scoped** and **client-side**: a new thread, a reload, or a new
  session defeats it.
- **Context-sensitive normalization drift.** Every ask is first rewritten to a
  canonical standalone form (`normalize_question`, `llm.ex:148`). When the
  re-ask happens *inside the same thread*, `recent_context` is non-empty, so
  normalization takes the `recent_context != []` branch (`llm.ex:155`), **skips
  the text cache**, and re-normalizes "against the conversation" — treating a
  literally identical question as a *followup* and rewriting it differently.
  Different cleaned text → different embedding → it can fall under the 0.92 gate
  → pool miss → fresh LLM answer → second row.

**Root cause:** there is no durable, user-level "did this person already ask
this" check. Matching rides on ephemeral thread state plus an embedding
threshold whose *input drifts* via context-sensitive normalization.

## Goals

- Asking the literally same question twice → **one** Q&A row, second served from
  cache, regardless of thread / reload / session.
- A reworded repeat by the same person is served from their own history when it
  is confidently the same question.
- Never serve a cached answer to a question that is only *near* a prior one
  (materially different but embedding-close).
- No schema change, no new table.

## Design — three tiers

Precedence inside `LLM.ask/5`, first hit wins, else call the LLM:

1. **Shared pool** (existing `find_similar_question_in_pool`) — curated/trusted
   cross-user answers win first; unchanged.
2. **Same-user exact dedup** (new, deterministic) — the asker's own prior answer
   whose *normalized* text matches exactly.
3. **Same-user semantic fallback** (new, tight threshold) — the asker's own prior
   answer that is embedding-close above a stricter threshold than the pool.

### Piece 1 — don't treat an identical re-ask as a followup

In `normalize_question/3` (`llm.ex`): before normalizing, if the raw question
(trimmed, case-insensitive) equals any question in `recent_context`, normalize
**standalone** — call `do_normalize(game, raw, [])` instead of passing context.
Identical re-asks then collapse onto the original's canonical form + embedding
and hit tier 1/2 instead of being rewritten as a followup. Genuine followups
("what about that?") never text-match a prior turn, so they are unaffected.

### Piece 2 — same-user exact dedup (tier 2)

New query `Games.find_user_duplicate(game_id, user_id, cleaned, raw)`:

- `user_id` matches the asker, same `game_id`,
- `refused == false`, `blocked == false`, `needs_review == false`,
- answer present and not the in-flight sentinel `"Thinking..."`,
- normalized-text match, case-insensitive: `lower(cleaned_question) == lower(cleaned)`
  OR (`cleaned_question IS NULL` AND `lower(question) == lower(raw)`),
- most recent first; `limit 1`.

Returns `nil` or `{question_log, tier}` where `tier = pool_tier(row)`.

### Piece 3 — same-user semantic fallback (tier 3)

New query `Games.find_user_similar(game_id, user_id, embedding, opts)`:

- same eligibility filters as Piece 2 (own rows, not refused/blocked/needs_review,
  answer present, not "Thinking..."),
- `question_embedding` not nil,
- cosine distance ≤ `user_dup_distance_threshold()` (**stricter** than the pool),
- order by ascending cosine distance; `limit 1`.

New setting `user_dup_similarity_threshold`, default **0.95** (distance = 1 − sim),
parsed the same way as `pool_similarity_threshold` (`games.ex:1745`). Stricter
than the 0.92 pool because same-user history has **no curation/trust gate** — a
false match serves a wrong answer with nothing behind it.

### Serving a same-user hit

Tiers 2 and 3 return the **same result shape** the pool path already produces
(`llm.ex:67`): `answer`, `cited_passage`, `cited_page`, `verdict`,
`provider: "pool"`, `model: "cached" | "cached-unverified"`, `pool_hit: true`,
`tier`, `verified`, `source_question_log_id`, `question_embedding`,
`cleaned_question`. So `AskWorker` copies the answer into the pre-logged row,
sets `pool_source_id`, and (because `pool_hit?` is true) skips re-pooling
(`ask_worker.ex:161-167`) — no behavior change needed in the worker.

`tier` comes from `pool_tier/1` on the served row (a private, un-pooled own-row
is `:provisional` → `model: "cached-unverified"`).

Record the save: call `RuleMaven.LLM.Savings.record_cache_hit("ask", game_id, user_id)`
on tiers 2 and 3, matching tier 1 (`llm.ex:63`).

### Control flow in `LLM.ask/5`

```
cleaned       = normalize_question(...)        # Piece 1 applies here
embedding     = embed(match_text)
pool_hit      = !skip_pool && embedding && find_similar_question_in_pool(...)
user_exact    = !skip_pool && find_user_duplicate(game.id, user_id, cleaned, raw)
user_semantic = !skip_pool && embedding && find_user_similar(game.id, user_id, embedding)

cond:
  pool_hit      -> serve (tier 1)
  user_exact    -> serve (tier 2)
  user_semantic -> serve (tier 3)
  true          -> call_llm(...)
```

`user_id` is already threaded into `LLM.ask` via `opts[:user_id]`
(`ask_worker.ex` passes it). When `user_id` is nil (no signed-in asker), tiers 2
and 3 are skipped.

## Out of scope

- Cross-user serving of un-pooled answers (stays pool-gated by citation).
- Any schema/table change.
- Touching the regenerate/retry paths (they intentionally `skip_pool`).

## Testing

- Same user asks an identical question twice → one row; second is a cache hit
  (`pool_hit`, `pool_source_id` set), no second LLM `ask` call.
- In-thread repeat (non-empty `recent_context`) → Piece 1 normalizes standalone;
  no second row.
- Genuine followup ("what about that?") → still answers fresh (no false dedup).
- Same user reword that normalizes identically → tier 2 hit.
- Same user reword, distinct normalization, embedding ≥ 0.95 → tier 3 hit.
- Same user reword, embedding between 0.92 and 0.95 → **no** hit (answers fresh):
  guards against wrong-answer false positives.
- Different user, asker's row un-pooled → **not** cross-served (tiers 2/3 are
  user-scoped; pool stays citation-gated).
- `user_id == nil` → tiers 2/3 skipped, behaves as today.
