# Escalate-only-on-suspicion grounding critic

## Problem

`RuleMaven.Games.Citations.valid?/4` only checks that a cited quote/page
actually appears in the retrieved source chunks. It never checks that the
free-form `answer` text the model wrote is entailed by that quote. A model
can cite a real passage correctly and still append an unsupported
consequence clause to the answer (observed case: a Horrified rules answer
correctly quoted the Terror Level rise conditions from p.9, then added an
invented claim that defeating a Monster lowers Terror Level — nothing in
the cited passage supports that, and nothing in the pipeline caught it).

The existing system prompt (`lib/rule_maven/prompts.ex`, `@answer`) already
instructs the model strongly against this ("ONLY the rulebook text
provided", "Do NOT infer, extrapolate, or use general board game
knowledge"). This is a compliance failure past that instruction, not a
permissive-wording problem, so the fix is a verification step, not a prompt
rewrite.

## Approach

Add a cheap heuristic gate in front of an escalated critic call, mirroring
the existing cheap-first/escalate-on-disagreement pattern already used by
the extraction pipeline's faithfulness critic (`parse_critic_verdict/1`,
`llm.ex`).

Runs only on fresh generations (the cache-miss path through
`RuleMaven.LLM.ask/5` → `call_llm/8`). Pool/cache hits already passed this
check when they were first generated, so re-serving a cached/pooled answer
does not re-run it.

### Step 1 — Heuristic gate (free, no LLM call)

New `RuleMaven.Games.Citations.suspicious?/2`, given the generated `answer`
string and the list of cited quote strings. Flags `answer` as suspicious
when either:

- **Keyword delta**: `answer` contains one or more consequence/causal
  trigger words (e.g. lowers, raises, increases, decreases, unless, only
  if, must, cannot, instead, always, never, before, after) that do not
  appear (case-insensitive substring match) anywhere in the cited quote
  text.
- **Length ratio**: `answer` word count exceeds 2.5x the combined word
  count of the cited quotes.

Not suspicious → return the answer as-is, identical to today's behavior,
zero added cost.

### Step 2 — Critic call (escalated, cheap model)

Only reached when Step 1 flags. New prompt key `"grounding_critic"` added
to the `RuleMaven.Prompts` registry (same DB-override mechanism as
`"answer"` — `Prompts.render/2`, `Prompts.template/1`). Called via
`model(:cheap)` (existing helper, `llm.ex:1237`, already used for the
cleanup pass — no new model/config knob).

Input: the cited quote(s) + the generated answer.
Output (JSON, matching the existing `decode_answer`-style parsing
convention): `{"verdict": "grounded" | "hallucinated", "flagged_clause":
"<string or null>"}`.

- `grounded` → false positive from the heuristic; return the answer as-is.
- `hallucinated` → go to Step 3.

### Step 3 — Single full re-ask

Re-run the full answer-model call (`call_llm/8`) with the same retrieved
context chunks, but with one line appended to the rendered system prompt
naming `flagged_clause` as a claim to avoid repeating. Run Step 1 + Step 2
once on the new answer. No further retries regardless of outcome.

- Second pass clears (not suspicious, or critic says grounded) → return it.
- Second pass still flags `hallucinated` → discard it. Return the existing
  refusal path already used for "not covered" answers (`refused: true`,
  handled today in `ask_worker.ex`) — no new refusal mechanism.

## Data model

No new `QuestionLog` fields. Reuses existing `verdict` / `refused`. The
critic call is logged through the existing `RuleMaven.LLM.Log` (`llm_logs`)
path like any other LLM call, so its cost is already visible in the
existing savings/cost dashboard without new plumbing.

## Cost shape

- Not suspicious (expected majority of answers): +$0.
- Suspicious, critic clears it (false positive): one cheap-model call,
  ~500 input / ~50 output tokens — effectively rounding-error cost per
  answer.
- Suspicious, critic confirms, retry: up to two cheap-model calls plus two
  full answer-model calls for that one question — the initial critic call,
  the retried answer (a second full answer-model call), and (if the retry's
  own free heuristic also trips) a second cheap-model critic call re-checking
  the retried answer before deciding whether to fall back to refusal. The
  second critic call is skipped whenever the retry isn't suspicious per the
  free heuristic.

Total added spend scales with the heuristic's flag rate, which is tunable
by adjusting the trigger-word list and the length-ratio threshold if the
false-positive rate needs tightening later.

## Out of scope

- No changes to `Citations.valid?/4` itself (quote/page grounding stays as
  is — this adds a parallel check for answer-prose grounding, it doesn't
  replace the existing one).
- No admin UI changes for the new prompt key beyond it appearing in the
  existing Prompts registry admin screen like any other prompt.
- No retry loop beyond the single re-ask (deliberately simple; revisit if
  real-world hallucination rate after retry turns out non-negligible).
