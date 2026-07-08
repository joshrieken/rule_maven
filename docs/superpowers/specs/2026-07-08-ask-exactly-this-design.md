# Ask Exactly This — verbatim re-ask escape hatch

## Problem

When a question is normalized, the answer runs on the rewritten (cleaned) form.
If the rewrite changed the asker's meaning, the only current escape hatches
(`not_my_question`, Report, Regenerate) all **re-normalize** the text — there is
no way to force the answer to run on the literal words the asker typed.

## Feature

A single button, **"Ask exactly this"**, that re-asks the asker's verbatim
original wording (no normalization, no cache) and silently records a
normalization-mismatch signal for admins.

## Visibility / gating

- Renders only on the asker's **own**, **answered** thread where normalization
  actually changed the wording — the same `normalization_changed?` gate that
  drives the "↳ You asked:" disclosure.
- Not shown on pending ("Thinking…") or ⚠️ error rows.
- Placement: the existing answer action row next to Report / Regenerate
  (`show.ex` ~4075). Uses the shared `btn-*` system (outline, xs). One primary
  per row is unchanged — this is a secondary/outline button.

## Behavior on click (`ask_exactly` event)

1. Reuse `resubmit_question`'s existing gating: asks-enabled check, quota + daily
   $ cap (`check_rate_limit`), retry cooldown, own-row ownership.
2. **Silent admin signal** (best-effort, never blocks the ask):
   - `Audit.log(current_user, "question.ask_verbatim", target_type: "question",
     target_id: id, target_label: original, metadata: %{original: raw, cleaned:
     cleaned})`.
   - `Games.record_pool_mismatch(q)` — bumps the existing `mismatch_count` that
     already surfaces on the moderation dashboard.
   - No modal, no `report_answer` (that is answer-focused + pulls from Community —
     wrong semantics and would spam moderation).
3. **Verbatim re-ask:** re-ask `old_q.question` (the raw text read from the DB,
   not the cleaned bubble content) with `skip_pool: true` and the new
   `skip_normalize: true` flag.

## New plumbing (the only genuinely new code)

Thread a `skip_normalize` flag from the LiveView through `AskWorker` args into
`LLM.ask/5`:

- `AskWorker`: read `args["skip_normalize"]`, pass `skip_normalize: true` to
  `LLM.ask`.
- `LLM.ask`: when `skip_normalize` is set —
  - skip the `normalize_question` LLM call,
  - set `cleaned = ""` so `match_text` is the raw question and
    `cleaned_question` is stored `nil` (no disclosure on the new row),
  - skip the early `:ask_normalized` broadcast.
- `skip_pool: true` already short-circuits every cache/pool/user-dedup tier
  (they are all gated on `!skip_pool`), so no cached normalized answer is served.

Net result: the new row answers the exact words and shows **no** "You asked"
disclosure — the asker sees their own wording answered directly.

## User feedback

Flash after click:
> "Asking your exact wording — flagged the rewrite for review."

## Data / migrations

None. Reuses `question_logs.mismatch_count` and the `audit_logs` table. Add the
`"question.ask_verbatim"` action to `Audit.actions/0` so the `/admin/audit`
filter dropdown lists it.

## Docs

Add a `/help` FAQ entry describing "Ask exactly this" (help-tours-upkeep rule).

## Testing

1. **LiveView** — on a normalized, answered, own thread, clicking "Ask exactly
   this":
   - enqueues an `AskWorker` job whose args carry `skip_normalize: true`,
     `skip_pool: true`, and the **raw** question text;
   - writes a `"question.ask_verbatim"` audit entry;
   - increments the question's `mismatch_count`.
   - Button absent on non-normalized / pending / error / other users' rows.
2. **LLM** — `LLM.ask(game, q, [], [], skip_normalize: true)`:
   - does not invoke the normalize LLM call (raw text used as `match_text`);
   - emits no `:ask_normalized` broadcast;
   - returns `cleaned_question: nil` (or "").

## Out of scope (YAGNI)

- No second "Report" button (verbatim ask carries the signal).
- No new admin normalization-quality dashboard — the audit entry + existing
  `mismatch_count` are the review surface.
- No change to the default normalization behavior for first-time asks.
