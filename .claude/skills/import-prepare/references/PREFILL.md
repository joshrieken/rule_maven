# Pre-filling the answer pool

Goal: write MANY more question/answer pairs for a game so that real players'
questions are served from the pre-verified pool instead of a live model. Every
answer you write is shown to players verbatim as an authoritative ruling, so
accuracy beats volume — but we want volume.

Source of truth: the transcription JSON given in your task (pages with
"sheet", "printed", "text"). Use ONLY that text. Never add rules from memory of
the game, other editions, expansions, FAQs or the internet that are NOT in the given transcription file(s) (an official FAQ transcribed as its own document IS a source).

## What to write

`{"answers": [ {question, answer, verdict, citations}, ... ]}` — the exact
answer format of AUTHOR.md ("answers" section): read that section and follow it
(1-4 sentences, first sentence settles it, verdict rules, 1-3 VERBATIM
citations of 10-30 words from ONE page each, page = printed or sheet).

Questions: what a real player asks MID-GAME, in plain player phrasing (mix
terse and full: "can I trade on my first turn?", "what happens if the bank runs
out of ore?"). Cover the WHOLE book systematically, section by section:
setup by player count, turn structure and order, every action/card/power/
component, timing windows, limits and maxima, edge cases and conflicts between
two rules, ties, running out of components, end-game triggers, scoring and
tie-breaks, variants/modes the book defines. Prefer questions people get WRONG.

Do NOT duplicate a question in the "existing" list file given in your task, or
another one of yours (same meaning = duplicate, even if worded differently).
Rephrasings of the same ruling are wasted slots.

## Accuracy rules (hard — these come from real wrong answers)

1. NO UNSUPPORTED NEGATIVE OR REPLACEMENT CLAIM. Never write "you do not…",
   "cannot…", "instead…", "skip…", "only…", "never…" unless a cited quote states
   that restriction. Real failure: "When bidding 0 you do not take a card;
   instead you trade" — the book's turn list said: choose a card, recruit a
   Hero, THEN trade. When a rule is a step in a sequence, read the whole
   sequence and state where the step falls.
2. If the book does not settle a question, DON'T write that question. Never
   answer "the rulebook doesn't say" — just pick another question.
3. Never infer from illustrations/diagram captions beyond their printed labels.
4. Numbers, counts, costs, ranges and player-count conditions must be copied
   exactly; say which mode/variant a rule belongs to when modes differ.
5. Yes/no questions start "Yes," / "No," and use verdict legal/illegal; a
   negatively phrased question ("can't I…", "is there a penalty…") gets "info".

## Self-check (required before finishing)

Run python over your file:
- json.load works; every entry has the 4 keys; verdict in legal|illegal|info.
- every citation quote, normalized (lowercase, non-alphanumerics → single
  space, trimmed), is a substring of the normalized text of the page whose
  printed (or sheet, if printed is null) == "page"; quotes 10-30 words.
- no two questions normalize the same; none matches a line in the existing
  list (normalized).
- every answer containing (do not|don't|does not|doesn't|cannot|can't|never|
  instead|skip|only|no longer|not allowed) has at least one citation whose
  quote contains a negation/restriction word (not|no|never|cannot|only|
  instead|except|unless|must|may not). Fix or drop the ones that fail.
Fix everything that fails. Report: count written, sections covered, any
answers you were unsure of (prefer dropping them). Do not paste content.
