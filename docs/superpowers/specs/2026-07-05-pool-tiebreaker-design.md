# Answer-pool paraphrase tiebreaker

## Problem

The cross-user answer pool (`Games.find_similar_question_in_pool/2`, games.ex:2135)
requires cosine similarity ≥ 0.92 (`pool_similarity_threshold` setting, default
0.92, games.ex:2367) to serve a cached answer. Confirmed via direct DB query:
"What is the d20 used for?" vs "What does the d20 do?" — both rows fully
eligible (`pooled: true`, `citation_valid: true`, not stale/refused/needs_review)
— embed at cosine similarity **0.896**, just under the 0.92 floor. Result: a
second user asking an obvious paraphrase gets a full fresh generation instead
of the cached, already-vetted answer.

Lowering the threshold outright risks false-positive pool matches (serving a
wrong cached answer for a related-but-different question). This design adds a
cheap LLM equivalence check for the ambiguous band instead of blindly loosening
the floor.

## Design

### Ordering change in `LLM.ask/5` (llm.ex:35)

Current order: own-user exact dup → cross-user pool → own-user semantic
fallback (0.95) → fresh generation.

New order: **own-user exact dup → own-user semantic fallback (0.95) → cross-user
pool → fresh generation.**

Rationale: own-user fallback is a plain cosine query, no LLM call, and stricter
(0.95) than the pool tier. Checking it first resolves the common "I'm
rephrasing my own question" case for free, before any pool query or tiebreaker
LLM call is spent. Pool lookup already has no `user_id` filter (llm.ex:58-64),
so reordering does not remove any coverage — it only changes which check
resolves a match first.

### Widened pool threshold + tiebreaker band

`find_similar_question_in_pool/2` (games.ex:2135) threshold param widens from
the direct-hit floor (0.92) down to **0.85**. The existing query already
returns a single best candidate (`limit: 1`, trust-first/distance ordering,
games.ex:2160-2178) — no multi-candidate loop needed.

Caller (`LLM.ask/5`) inspects the returned row's actual cosine similarity:

- **≥ 0.92**: direct hit, serve immediately (unchanged behavior).
- **0.85 – 0.92**: ambiguous band. Call new tiebreaker (below) with the
  candidate's question text and the new asker's question text.
  - Tiebreaker **yes** → serve the pool row via the existing pool-hit path
    (same bookkeeping as a direct hit).
  - Tiebreaker **no**, or the tiebreaker call itself errors/times out →
    treat as a miss, fall through to fresh generation. Never block or fail
    the request on tiebreaker failure.
- **< 0.85**: miss, straight to fresh generation (unchanged).

### Tiebreaker prompt

New entry in the Prompts registry (per standing rule — no hardcoded LLM
prompts). Input: candidate row's question text (`display_question/1`) and the
new asker's question text. Instruction: strict equivalence check — same
underlying rules question, not just same topic. Output: yes/no only.

Model: existing `model(:cheap)` tier (gemini-2.5-flash, llm.ex:9/281) — no new
model wiring.

### Logging

Plain `Logger.info` on tiebreaker decision (candidate id, both questions,
similarity, yes/no) — inline request-path code, not a background worker, so
it does not go through the Job log convention (start_run/event/finish_run is
for durable Oban workers).

## Testing

- Unit test: `find_similar_question_in_pool/2` with widened 0.85 threshold
  returns a candidate in the ambiguous band that it previously excluded.
- Unit test: tiebreaker function with mocked cheap-model yes/no responses —
  covers yes, no, and error/timeout (must resolve to miss, not raise).
- Integration test: reproduce the exact repro case — two users, two
  phrasings ("What is the d20 used for?" / "What does the d20 do?"), same
  game/expansion set, expect the second ask to serve the first's cached
  answer after a tiebreaker "yes".
- Regression: existing direct-hit (≥0.92) and own-user-first-in-order tests
  still pass with the reordered flow.
