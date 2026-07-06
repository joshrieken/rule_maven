# LLM Call Trace (per-question audit log) — Design

Date: 2026-07-06

## Goal

Admin, viewing a Q&A thread in the game chat, can expand an "LLM trace" panel
under any answer and see every LLM call made to produce it — operation, model,
tokens, estimated cost, duration, success/failure — plus totals. At a glance:
the process the system went through to arrive at the answer (or a refusal),
including retries, escalations, tiebreakers, critics, and restyles.

## Existing infrastructure

- `llm_logs` (RuleMaven.LLM.Log) already records every chat-completion call:
  provider, model, operation, prompt/completion/total tokens, duration_ms,
  success, error_message, game_id, user_id. Written by `LLM.log_llm/7` on both
  the real HTTP path and the mock path.
- `RuleMaven.LLM.Pricing.cost(model, prompt_tokens, completion_tokens)` gives
  a USD estimate at read time — no cost column needed.
- The entire ask pipeline (normalize → question embed → user-dup check → pool
  tiebreaker → ask → grounding critic → refusal escalation → truncation/bad-
  answer retries → inline persona restyle) runs synchronously inside
  `AskWorker.perform/1`.
- Admin "History" panel in `GameLive.Show` is the UI pattern to mirror:
  lazy-loaded on toggle, `MapSet` of open ids + cache map in assigns.

## What's missing

1. No link from an `llm_logs` row to the question/answer it served.
2. Embedding calls (`RuleMaven.Embed`) are not logged at all.
3. No query/UI to view calls per question.

## Design

### 1. Schema

Migration: `alter table(:llm_logs) do add :question_log_id, :bigint end` +
index on `question_log_id`. Deliberately **no FK**: llm_logs is audit data and
must survive question-row deletion (regenerate and dedup both delete rows).

### 2. Capture — Logger.metadata, not opts threading

`AskWorker.perform/1` sets `Logger.metadata(question_log_id: id)` first thing.
`LLM.log_llm/7` resolves the id as
`opts[:question_log_id] || Logger.metadata()[:question_log_id]`.

Because every call in the ask pipeline happens in the worker's own process,
this tags all of them — including nested retries and the pool tiebreaker —
with zero signature changes. Same one-liner added to `VoiceWorker` and
`TagQuestionWorker` (both receive `question_log_id` in args) so on-demand
restyles and tagging attach to the same trace.

`Logger.metadata` is per-process and set at the top of each Oban job, so
there is no leakage between jobs even with process reuse (each perform
overwrites it; workers without the line never read it — only `log_llm` does,
and it falls back to `nil`).

### 3. Embedding calls

`Embed.embed_batch/1` gains timing + a log write, **gated on
`Logger.metadata()[:question_log_id]` being present** — question-path embeds
get a row (operation `"embed"`), bulk chunk-embedding during ingest stays
unlogged (would flood the table). Token usage recorded when the response
includes it; `Pricing.cost` returns 0 for unknown embed models and the UI
shows "$0.0000" (accepted — embeds are ~free).

### 4. Query API

`LLM.calls_for_question(question_log_id)` → `%{calls: [...], totals: %{count, cost, duration_ms, tokens}}`.
Each call: inserted_at, operation, provider, model, prompt/completion/cached
tokens, cost (Pricing), duration_ms, success, error_message. Ordered
inserted_at ASC, id ASC (chronological process view).

### 5. UI (GameLive.Show)

Next to the admin-only "History" button under each assistant message:
"▸ LLM trace" (same conditions: `@is_admin`, assistant, not history entry,
not pending). Toggle event `toggle_llm_trace` with the question id; lazily
fetches via `calls_for_question` into `@llm_traces` map, `@llm_trace_open`
MapSet — exact mirror of the history panel mechanics.

Panel content:
- Totals line: `N calls · $0.0123 · 14.2s · 45,678 tokens`.
- One row per call: `HH:MM:SS · operation · model · p/c tokens (cached n) ·
  $cost · duration · ✓/✗`. Failed calls show error_message underneath,
  truncated, full text in `title`.
- Empty state: "No LLM calls recorded." (pool/cache hits legitimately make
  zero or one call — the trace showing only `pool_tiebreaker`, or nothing,
  is itself the answer to "how did it arrive at this").

Only calls tagged with this question row's id are shown. Prior regenerate
versions live under the existing History panel; their traces died with their
rows' ids (rows persist in llm_logs but the old question id is only reachable
via audit metadata — out of scope for v1).

## Alternatives considered

- **Thread `question_log_id` through opts everywhere**: explicit but touches
  ~15 private function signatures across LLM/Voices; high churn, easy to miss
  a retry path. Rejected.
- **New `llm_call_traces` table**: duplicates llm_logs. Rejected.
- **Store cost at write time**: pricing table changes would freeze stale
  costs; read-time derivation matches the existing cost dashboard. Rejected.

## Testing

- `log_llm` picks up `Logger.metadata` question_log_id (mock LLM path writes
  llm_logs rows already, so a `chat/3` call under set metadata asserts the
  column).
- `calls_for_question/1` returns chronological calls + correct totals.
- AskWorker integration: after a mocked ask, llm_logs rows for the question
  id exist.
- LiveView: admin sees trace button and rows after toggle; non-admin sees
  neither.
