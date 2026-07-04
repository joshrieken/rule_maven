# Fun/Auto-Gen Features Backlog

Not specs yet — ideas queued for future brainstorming sessions. Difficulty badge (shipped 2026-07-04) came from this same batch; FAQ mining idea was dropped (already solved better by the existing trust/vote-quorum auto-promotion, see `direct_promotion_worker.ex`).

## Deferred from original batch

1. **Auto game icon/thumbnail** — generate/fetch when missing. Decision needed: pull BGG art vs LLM image gen.
2. **Auto rules-conflict flagger** — LLM scans rulebook for ambiguous/contradictory rules, pre-generates "gotcha" callouts. Riskiest of the batch (false-positive risk on what counts as a real conflict).
3. **Auto session recap** — after N questions in a sitting, LLM summarizes "what you learned this session."

## New ideas (not yet scoped)

4. **House rules tracker** — let a group log their own house-rule variants per game; LLM checks each against the actual rulebook and flags where it deviates from RAW ("as written"), so house rules are visible/documented instead of tribal knowledge. Differentiates from pure Q&A.
5. **Rules-based icebreaker quiz** — auto-generate a short trivia quiz from the rulebook (same LLM pass style as "Did you know?") for pre-game warmup, especially for teaching a new group.
6. **Printable one-page cheat/scoresheet** — condense the existing setup checklist + scoring rules into a single printable card. Could reuse the CheatSheet renderer already in place, just a new content shape.
7. **Cross-game "if you know X, here's what's different"** — since chunks are already embedded, surface mechanic-similarity hints across games in a user's library (e.g. "like Wingspan but engine-building instead of card-drafting"). Needs a similarity threshold and probably a curated allowlist to avoid noise.
8. **Errata/edition diff** — when a rulebook gets re-uploaded (new edition/errata), LLM diffs old vs new and surfaces "what changed" instead of silently replacing. Ties into the existing extraction/versioning pipeline.
9. **TTS narration for Did-you-know / setup checklist** — accessibility + tabletop-adjacent "read this aloud while setting up" convenience. Web Speech API already used for voice *input* (`VoiceDictation`); this would be the output side.

## Explicitly parked, not recommended

- Light gamification (streaks/badges for asking questions) — flagged but likely scope creep; the app's value is rules clarity, not engagement metrics. Only revisit if user retention data specifically asks for it.

## Recommended next pick

**House rules tracker (#4)** — most differentiated, reuses existing citation/verdict infrastructure (verdict stamps, confidence meter) rather than inventing new LLM surface area, and has a clear "why" (documents tribal knowledge groups already accumulate informally).
