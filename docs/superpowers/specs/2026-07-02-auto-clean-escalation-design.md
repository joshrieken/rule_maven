# Auto-escalating page cleanup — design

Date: 2026-07-02
Status: approved

## Problem

Cleanup runs at one fixed level (light/standard/aggressive) for a whole
document. All four failure modes occur in practice:

- **Junk survives** — level too gentle; headers/footers/OCR garble remain.
- **`kept_raw` reverts** — the length-based drop guard rejects legitimate
  aggressive cleans and silently bakes the raw page back in.
- **Unchanged output** — the model returns its input verbatim; no clean
  happened.
- **Over-cleaning** — aggressive drops real rule content.

The opt-in critic only *logs* defects; nothing acts on them. There is no
feedback loop, so the admin discovers bad pages by eye and re-runs whole
documents at guessed levels.

## Goal

Per-page closed loop: clean → verify → escalate/de-escalate → converge, at the
least cost that preserves quality. Happy-path pages must cost what they cost
today (one clean call, no critic).

## Approach (chosen)

Typed-verdict single-retry, verified by a tiered checker (free heuristics
first, LLM critic only on suspects). Loop runs **inline per page** inside the
existing `CleanupWorker` job. Rejected alternatives: run-all-levels-pick-best
(2–3× cost on every page) and escalate-only (over-cleaning confirmed to
happen, so de-escalation is required).

## 1. Verdict engine

### `RuleMaven.Extract.CleanCheck` (new, pure — sibling of `Extract.Gate`)

Deterministic, free scoring of one clean attempt. Inputs: raw body, cleaned
output, level used, `cleanup_page` status. Signals:

- **Surviving garble**: per-line `Gate.wordish_ratio` on the output; symbol-soup
  lines that survived = under-clean signal.
- **Shrink envelope** per level — outside the envelope is suspect:
  - light: ~0–15% shrink expected
  - standard: ~0–30%
  - aggressive: ~10–70%
- **Unchanged on junky input**: status `:unchanged` while the input shows junk
  signals → suspect under-clean. `:unchanged` on clean input → accept.
- **Guard fired**: status `:guard_fired` → always suspect (critic adjudicates).

Returns `:accept` or `{:suspect, :under | :over | :both}`.

### Typed critic verdict

`cleanup_critic` prompt (Prompts registry — never hardcoded) rewritten to emit:

```
VERDICT: faithful | junk_remains | content_lost
- <defect bullet>
- <defect bullet>
```

`LLM.critique_cleanup` parses to `{verdict, defects}`. Unparseable verdict →
treated as `faithful` with a log line (critic failure never blocks or reverts
a cleanup — existing invariant).

## 2. Per-page loop (`CleanupWorker.clean_one`)

1. Clean at **standard** (auto mode always starts here).
2. `CleanCheck` heuristics. `:accept` → persist, done. No critic call.
3. Suspect → critic on (raw, cleaned):
   - `faithful` → accept. This includes short-but-faithful guard-fire cases —
     the guard no longer auto-reverts in auto mode.
   - `junk_remains` → retry at **aggressive**.
   - `content_lost` → retry at **light**.
4. The retried attempt is also critic'd. The best of the two attempts
   persists — ranked by critic verdict (faithful > junk_remains ≈ content_lost),
   heuristic score as tiebreak.
5. Still bad after the retry → persist the best attempt anyway and flag the
   page (existing `flagged` stat, job-log warn with the defect list).

**Budget:** max 2 clean calls + 2 critic calls per page, paid only by bad
pages. Typical page: 1 clean call, 0 critic calls.

The `cleanup_critic` Settings toggle is removed — the critic is integral to
the loop, not an opt-in extra.

## 3. API / UI

- The loop lives in the worker; `LLM.cleanup_page` stays single-shot. New
  behavior: in the auto flow the drop guard returns
  `{:ok, cleaned, :guard_fired}` (output kept) so the critic can adjudicate.
  The manual/legacy path (explicit level) keeps today's revert-to-raw guard.
- Level picker removed from the prepare and edit pages. Clean / Clean all /
  per-page Clean buttons enqueue `level: "auto"`. The worker still accepts
  explicit levels for mix tasks and jobs already in the queue.
- Job log reports the level path per page, e.g.
  `Cleaned page 12 (standard→aggressive, junk remained) — 1840→1211 chars …`.
- Flagged pages surface via the job log only; no new UI badge (YAGNI).
- No schema change. Attempts are held in memory inside `clean_one`; only the
  winning attempt persists to `pages[].cleaned`.

## 4. Testing

- `CleanCheck` unit tests: junky-input-unchanged → suspect; shrink inside
  envelope → accept; symbol-soup line survival → suspect-under; huge shrink at
  light → suspect-over; guard_fired → suspect.
- Critic parser tests: verdict line variants; defects without verdict;
  unparseable → `faithful` + log.
- Worker tests with mocked LLM: escalation path (standard→aggressive),
  de-escalation path (standard→light), best-attempt selection, flag on double
  failure, restart-resume (durable counter) unaffected by retries.
