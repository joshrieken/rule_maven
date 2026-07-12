# Unified publish gate for solo and group questions

Date: 2026-07-11

## Problem

`questions_log` rows currently reach public visibility through two different, inconsistent mechanisms depending on whether the ask came from a solo user or a group (crew):

- **Solo rows**: born `browsable: true`. `AskWorker` inline-calls `Games.mark_pooled/1` the moment an answer is citation-valid — no content screen ever runs. `DirectPromotionWorker` can then auto-promote to `visibility: "community"` on vote quorum alone, with zero check of what the text actually contains.
- **Group rows**: born `browsable: false, pooled: false`. `AskWorker` enqueues `PublishCheckWorker`, which screens the scrubbed question text (and the answer, `also_asked`, and `followups`) for real-person identification before it may set `browsable: true, pooled: true` together. Only then is the row eligible for listing or vote-based promotion.

This asymmetry was never a deliberate privacy-tiering decision — it's an artifact of the group feature being added later with a stricter gate, while solo rows kept their original, unscreened path. The two populations should follow the same rule: any row (solo or group) that can become publicly listed or vote-promotable must first pass the same content screen.

## Goals

- One gate, one code path, for both solo and group rows: no row may become `browsable`/vote-promotable without passing `PublishCheckWorker`.
- Automated auto-promotion (`DirectPromotionWorker`, vote quorum) is fail-closed for both populations, exactly as it already is for group rows.
- Manual curator promotion (admin "verify"/"force publish") remains a human decision, but is informed by the same screen's result rather than bypassing it silently.
- No existing published content is retroactively hidden.

## Non-goals

- Not changing the screen's actual criteria (still "does this identify a real person outside the game").
- Not backfilling/re-screening rows published before this change.
- Not building a general moderation queue beyond what's needed to surface stuck rows to an admin.

## Design

### 1. Data model

- `questions_log.browsable` default changes from `true` to `false` at the schema level. This governs new rows only.
- `RuleMaven.Games.QuestionLog`'s insert-time changeset helper (currently `default_group_unbrowsable/1`, gated on `is_nil(group_id)`) is generalized — renamed (e.g. `default_unbrowsable/1`) and its group-only condition dropped. It force-sets `browsable: false` on every insert unless the caller explicitly passed a value, for any row, not just group rows.
- `pooled` keeps its existing meaning and column; no schema change needed there.
- **No column added** for tracking the screen's outcome — the existing `Jobs` log (keyed on `{"question_log", id}`) already records every terminal state (`"Cleared — published."`, `"Flagged — left unbrowsable."`, `"Unreadable reply..."`) and is reused as the audit trail for both populations.

### 2. `AskWorker`

Current group-only branch:

```elixir
if group_id do
  if updated.citation_valid and not skip_normalize do
    PublishCheckWorker.enqueue(question_log_id)
  end
else
  Games.mark_pooled(updated)
end
```

Becomes unconditional:

```elixir
if updated.citation_valid and not skip_normalize do
  PublishCheckWorker.enqueue(question_log_id)
end
```

- `skip_normalize` ("Ask exactly this") rows still never pool or publish, solo or group — unchanged behavior, just no longer written as a group-only rule.
- The surrounding guard's crew-specific helper (`unscrubbed_crew_row?/3`) is generalized to apply the same "not yet scrubbed" check regardless of `group_id` — same logic, broader scope, not renamed to something crew-specific.
- `never_pool` and `consent_withdrawn?/1` already apply identically to both populations; no change.

### 3. `PublishCheckWorker`

- `screen/2`'s function head drops `when not is_nil(gid)` — matches any row (`group_id` nil or set), same other guards (`browsable: false`, `citation_valid: true`, `cleaned_question` is a binary).
- Moduledoc is rewritten from "Screens a GROUP question's..." to describe the gate as population-agnostic.
- **"no" outcome (clears the gate, sets `browsable: true, pooled: true`):** the SQL currently inner-joins `groups` and requires `contribute_to_community == true` — this must become conditional on `group_id`. When `group_id` is set, keep the join and consent check unchanged. When `group_id` is nil, skip the join entirely; solo rows have no group-level consent flag (their only consent lever is the existing `never_pool` flag, already enforced upstream before this worker is even enqueued).
- **"yes" outcome (un-pools an already-pooled row):** the SQL currently requires `not is_nil(q.group_id)` — relaxed to act on any row, so a solo row whose answer identifies a real person is pulled from the cache exactly like a group row would be.
- `screen_text/2` and all prompt/fence/untrusted-input handling are unchanged — already population-agnostic.

### 4. Admin surface

- New filter/badge on `/admin/questions`, same pattern as the existing `needs_review_count/0` badge: counts and lists rows where `browsable == false and citation_valid == true and not skip_normalize` — i.e. rows stuck behind the gate (mid-flight, ambiguous reply, or an explicit "yes").
- Each listed row shows the latest `Jobs` log message for its subject inline, reusing existing infra rather than adding a new outcome column.
- New admin action: **force-publish** — sets `browsable: true` (and `pooled: true` when `citation_valid`) directly, regardless of the automated screen's result. This is the human "final approval" lever. Writes its own `Jobs` audit entry (distinct run type, e.g. `"admin_override"`, attributed to the acting admin's user id) so the override is traceable separately from the automated worker's own log line.
- One surface serves both solo and group rows — no population-specific admin UI.

### 5. Migration

- One migration: `questions_log.browsable` column default `true → false`. Existing rows are **not** rewritten — this only changes the default applied to future inserts. Historical published content is unaffected.

### 6. Testing

- Extend the existing sabotage-style test pattern (`test/rule_maven/llm_group_gate_test.exs`): a solo citation-valid row must not become `pooled`/`browsable` until `PublishCheckWorker` clears it. Delete the gate in the test to confirm it fails without the fix.
- `PublishCheckWorker` "no" outcome: a solo row (`group_id: nil`) publishes without requiring any `groups` join or consent flag; a group row's existing behavior (consent-gated) is unchanged.
- `PublishCheckWorker` "yes" outcome: a solo row gets un-pooled the same way a group row does.
- New admin force-publish action: authz-gated to admins only, writes its own audit log entry, correctly sets `browsable`/`pooled`.
- Regression: rows created before the migration keep their existing stored `browsable`/`pooled` values — no retroactive rewrite.
- Full existing group-only test suite stays green — this change generalizes existing behavior, it does not alter it for group rows.

## Open questions / risks

- Cost: every solo ask now incurs one additional off-critical-path LLM call (`PublishCheckWorker`) before becoming cache-eligible, where today it's free and instant. Accepted explicitly as the cost of consistency and of closing the "unscrubbed row visible on the Unverified tab" gap.
- The screen asks a risk question ("does this identify a real person?"), not a publish-approval question — "no" is the safe/happy answer, "yes" is the flagged one. This inversion relative to the worker's name is a documentation trap for future readers, not a functional issue; addressed with a moduledoc clarification, not a rename (the prompt registry key `publish_check` is user-editable content and out of scope to rename).
