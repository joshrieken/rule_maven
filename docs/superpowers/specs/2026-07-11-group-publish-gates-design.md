# Group Publish Gates — Design

**Date:** 2026-07-11
**Status:** Approved
**Supersedes one decision in:** `2026-07-10-persistent-groups-design.md` (line 27, "never auto-pooled to community")

## Problem

Persistent groups shipped with a stated invariant — group content never leaks into
the community pool — that the code does not implement. `AskWorker` calls
`Games.mark_pooled/1` on every non-refused, citation-backed answer with no
`group_id` guard (`ask_worker.ex:374`). A group question therefore:

1. is served cross-user through the answer cache (`pooled == true` branch of
   `find_pool_candidates/3`),
2. appears in the public **Unverified** tab (`unverified_pool_questions/2` =
   `pooled == true and visibility != "community"`), listed **by question text**,
3. can reach full `visibility = "community"` on votes via `DirectPromotionWorker`.

The spec says walled; the code says ladder; nothing tells the user which.

## Decision

Keep the ladder (spec line 27 is **withdrawn**), and make it safe.

The leak that matters is not the *answer* — the cache already serves answer text
only, never the asker's wording or identity. The leak is the **question text** on
browse surfaces, and the **identity** attached to it. Today `pooled` does double
duty as both "servable by cache" and "listable in browse". Splitting those two
meanings is the whole fix.

A group row will be:

- **pooled** — its answer feeds the commons through the cache, anonymously, as
  today. This is what makes a group a net contributor rather than a black hole,
  and it is what feeds cold start.
- **browsable only after passing publish gates** — its *question text* becomes
  publicly listable only in scrubbed, canonical form, and only after both an
  LLM scrub and an independent LLM check agree it carries nothing personal.

## The gates

Four gates, in order of how much they are trusted. No single gate is a privacy
boundary on its own.

### Gate 1 — normalize scrubs on purpose

`normalize_question` already compresses a raw question to a standalone canonical
form ("resolve pronouns, add missing context, under 12 words, no game name").
That destroys voice and most incidental personal context as a side effect of
compression — but nothing in the prompt says to remove names, and it will keep a
proper noun it reads as load-bearing.

Amend the registry prompt to strip player names, proper nouns that are not game
terms, and personal narrative — keeping only the rules question. Registry-editable
(per the standing "LLM prompts in registry" rule), so it is tunable without a
deploy. Costs zero extra LLM calls.

**This is a scrubber, not a boundary.** It is an LLM, its failures are silent,
and a leak here is permanent and public. Hence gate 2.

### Gate 2 — an independent publish check

Before a group row becomes *browsable*, one cheap yes/no call on the canonical
text alone: does this contain a person's name or personal information?

- Same shape as `pool_tiebreaker` — one-word output, tiny prompt, tiny cost.
- Runs **once per row, off the critical path**, in an Oban worker. Never on the
  read path, so it costs nothing at serve time.
- **Fails closed.** "yes", a malformed answer, an error, or an exhausted retry
  all leave the row unbrowsable.

A false positive costs almost nothing (the answer still feeds the cache; only the
browse listing is withheld), so the check is tuned to be paranoid.

### Gate 3 — `skip_normalize` rows never browse

Deterministic, no LLM involved. "Ask exactly this" (`llm.ex:76`) deliberately
bypasses normalize and pins the **raw user text** as the canonical form. That text
is verbatim user prose and must never be published. `AskWorker` knows
`skip_normalize` from its own args and writes the row unbrowsable, permanently.

Without this gate, the entire mitigation has a hole straight through it: a user
who forces verbatim text would be publishing exactly the text the other gates
exist to scrub.

### Gate 4 — human override

Some questions are unsafe in **content**, not phrasing. "Is Marcus cheating?"
normalizes to a clean rules question and passes every automated gate above, and
still must not appear in a public list. Only the human knows that.

- **Per ask:** a "Keep this in the crew" toggle on the composer, visible when a
  group is active. Sets the existing `never_pool` flag (`ask_worker.ex:33`) — the
  row is neither pooled nor browsable. Fully sealed.
- **Per group:** a *Contribute answers to the community* setting on the group
  settings page, **on by default**. Off ⇒ every ask from that group is
  `never_pool`. A crew that wants a fully walled room gets the original
  spec's behaviour by flipping one switch. The A-vs-B choice becomes per-crew
  rather than global.

## Data model

One column on `questions_log`:

```elixir
add :browsable, :boolean, null: false, default: true
```

**Semantics:** may this row's *question text* be shown to someone who is not the
asker? Default `true` preserves every existing (non-group) row's behaviour exactly.

- Non-group asks: written `true`. No behaviour change anywhere.
- Group asks: written `false` at insert. The publish-check worker flips it to
  `true` only if every gate passes.
- `never_pool` asks (gate 4): written `false`, and never enqueue the check.
- `skip_normalize` group asks (gate 3): written `false`, and never enqueue the
  check.

One column on `groups`:

```elixir
add :contribute_to_community, :boolean, null: false, default: true
```

`browsable` is deliberately **orthogonal** to `pooled` and `visibility` — the same
move that made `group_id` orthogonal to `visibility` in the groups design, and for
the same reason: it avoids touching the dozens of queries that hard-code
`visibility == "community"`.

## Enforcement points

Three reads gate on `browsable`; everything else is untouched.

1. **`Games.unverified_pool_questions/2`** — add `q.browsable == true`. This is the
   public Unverified tab, and the surface the whole design exists to protect.
2. **`DirectPromotionWorker`** — add `q.browsable == true` to the candidate query.
   A row that may not be listed must not be auto-promoted to `community`, since
   promotion makes it listable everywhere.
3. **Browse rendering** — surfaces that list a group-origin row render
   `canonical_question`, never `question`. A group row with no canonical text is
   not browsable (it cannot have passed gate 2, which reads canonical text).

`find_pool_candidates/3` is **not** changed. It never exposed question text, so it
was never the leak. Its `pooled == true` branch continues to serve group answers
cross-user — that is the intended contribution.

Admin surfaces are unchanged: an admin already sees raw question text everywhere,
and manual promotion is a deliberate act by a trusted actor.

## The worker

`RuleMaven.Workers.PublishCheckWorker` — enqueued by `AskWorker` for group rows
only, alongside the existing `TagQuestionWorker` enqueue.

- Loads the row; bails unless `group_id` is set, `browsable == false`,
  `canonical_question` is present and non-empty, and the row is pooled and not
  refused/errored.
- Runs the publish-check prompt on `canonical_question`.
- `"no"` ⇒ `browsable = true`. Anything else (including any error) ⇒ leave `false`.
- Reports to the unified Jobs log, per the standing job-log convention.

Failing closed means a worker outage degrades to "group questions don't get
listed", never to "group questions get listed unchecked".

## Threat model — what this does and does not protect

**Protects:** the asker's raw phrasing and identity never leave the group. Public
surfaces show a ≤12-word canonical rules question that two independent LLM passes
agreed carries nothing personal, and a human could have vetoed.

**Does not protect:** a determined leak of *rules content* that is itself
identifying — e.g. a question about a house rule unique enough to fingerprint a
group. Accepted: the blast radius is a board-game rules question, and gate 4 is the
answer for anyone who cares.

**Residual risk, stated plainly:** we are trusting a prompt with a privacy
boundary. It is mitigated by an independent second gate, a deterministic exclusion,
and a human override — the same posture the grounding critic already runs under —
but it is not zero. The failure mode is a stray first name inside a rules question.

## Testing

- `unverified_pool_questions/2` excludes `browsable == false`.
- `DirectPromotionWorker` never promotes a non-browsable row, even above the trust
  floor with quorum.
- `PublishCheckWorker`: clean canonical ⇒ browsable; PII-flagged ⇒ stays false;
  missing canonical ⇒ stays false; LLM error ⇒ stays false (fail-closed).
- `AskWorker`: a group ask inserts `browsable == false`; a non-group ask inserts
  `true`; a `skip_normalize` group ask is never enqueued for the check.
- Group setting off ⇒ ask is `never_pool` ⇒ neither pooled nor browsable.
- Composer toggle sets `never_pool`.
- Browse surfaces render `canonical_question` for group rows.

Each gate gets a **sabotage check**: remove the guard, confirm the test goes red,
restore.

## Out of scope

- Trust/curator points for group asks. A group row is pooled-but-unbrowsable until
  it passes the check, so it collects no votes and earns its author no trust. That
  is a fairness wrinkle, not a blocker; revisit if crews complain.
- Retroactive scrubbing. The normalize cache is keyed on
  `{game_id, prompt_version, downcase(raw)}`, so the prompt change is
  forward-only — rows written before it keep their existing canonical text. No
  group rows exist in production yet (groups are unpushed), so there is nothing
  to backfill.
