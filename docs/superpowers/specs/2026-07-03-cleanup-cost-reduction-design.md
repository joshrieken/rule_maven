# Cleanup Cost Reduction — Design

**Date:** 2026-07-03
**Goal:** Cut rulebook-cleanup LLM cost (both the dashboard estimate and real token spend) without lowering output quality.

## Background / measurements

- Post-column-fix DungeonQuest cleanup (job run 157): 12 pages → 12 cleanup calls, 11.8k input / 13.9k output tokens on `deepseek/deepseek-v4-flash`. 7 of 12 pages returned "no changes"; each still paid a full-page rewrite in output tokens.
- Dashboard bills `deepseek-v4-flash` at the conservative default rate ($0.50/$1.50 per M) because it is missing from the `LLM.Pricing` table. Real OpenRouter rate is ~$0.089/$0.18 per M — the dashboard overstates cleanup ~6–8×.
- Output tokens are ~60% of cleanup spend; most of that output is echoing pages that needed nothing.

## Changes

### 1. Pricing table fix
Add `deepseek-v4-flash` (0.089 / 0.18) to `RuleMaven.LLM.Pricing`. Audit `llm_logs` for any other models currently falling to the default rate and add real rates for those too. No behavior change; dashboard drops to truth.

### 2. Lane-aware skip
Cleanup exists to repair extraction artifacts (OCR garble, hyphenation, running headers). Pages whose extraction lane was a vision model (`ensemble`, `vision`) with adequate confidence were already produced by an LLM transcription — cleaning them is a near-guaranteed no-op. In `CleanupWorker`:

- Skip the cleanup LLM call for pages with lane in `ensemble`/`vision` and confidence ≥ 0.6 (the same threshold `page_needs_review?/1` uses).
- Drift-sample a fraction of skipped pages (default 10%, reuse/parallel the extraction drift-sample setting pattern) through cleanup anyway and log the outcome to the job run, so "vision lane = already clean" keeps getting verified. A drift sample that produces real changes is a warning-level job event.
- Skipped pages count in the job summary ("N skipped (vision lane)").
- Page-level force (admin re-clean of a single page) and explicit non-`auto` levels (`light`/`standard`/`aggressive`) bypass the skip — an admin asking for cleaning gets cleaning.

### 3. NO_CHANGES sentinel
The cleanup prompt (in the Prompts registry, per standing rule — never hardcoded) gains an instruction: if the page needs no repairs, reply with exactly `NO_CHANGES` instead of echoing the page. Worker treats that reply as the existing "unchanged" outcome (same path as a verbatim echo today; CleanCheck's `:unchanged` branch already exists). False-positive risk (model says NO_CHANGES on a dirty page) is equivalent to today's model-echoes-input case and lands in the same CleanCheck/critic ladder.

**Prod note:** prompt override lives in the DB Prompts registry — the default changes in code, but any prod row overriding `cleanup` must be refreshed on deploy (same as the multi-source `prompt_answer` note).

## Out of scope
- Diff/edit-list output format (parser surface not worth it once 2+3 land).
- Any change to the CleanCheck heuristics, critic ladder, or escalation budget.

## Quality guarantees
- Pages that get cleaned run the exact same clean → CleanCheck → critic pipeline as today.
- Skips are observable (job log) and continuously audited (drift sample).
- Admin-forced cleans never skip.

## Testing
- Pricing: unit test that `deepseek-v4-flash` resolves to the new rate, not the default.
- Skip logic: pure decision function (`skip_cleanup?/2` or similar) unit-tested across lanes/confidences/levels.
- Sentinel: worker treats `NO_CHANGES` reply as unchanged (unit test at the response-handling function).
- Drift sample: deterministic test via injected sample decision.

## Expected impact
- Dashboard: ~6–8× drop immediately (pricing truth).
- Real tokens: ~60–70% fewer cleanup tokens on vision-heavy books (DungeonQuest: 12 calls → ~4 + occasional drift sample).
