# Authoring Prepare content + answers from a transcribed rulebook

Source of truth: the transcription JSON file(s) given in your task (pages with
"sheet", "printed", "text"). Use ONLY that text. Never add rules from memory of
the game, other editions, OTHER expansions or the internet. If the book doesn't say
it, don't write it.
When an official FAQ/errata file is given, it outranks the rulebook: if it
clarifies or changes a rule, answer per the FAQ and cite the FAQ page (cite the
rulebook too when useful).

Write ONE JSON file (path in your task):
{"enrichments": {...}, "answers": [...]}

## enrichments (all keys required)

- "suggestions": 5-7 categories, each {"category": str, "questions": [4-6 str]}.
  Real questions a player asks MID-GAME (edge cases, timing, "can I…",
  "what happens when…"), each answerable from the book. One question per string.
- "categories": 6-10 {"name", "description"} topic buckets covering the rules
  (used to tag questions). Names short ("Combat", "Setup").
- "cheat_sheet": markdown, ≤ 8000 chars. Terse bullet reference of the rules a
  table needs: turn structure, actions, key numbers, end/victory. Bold labels.
- "setup": {"components": [str per component line, with counts as printed],
  "setup": [{"title", "detail"} in order]}.
- "did_you_know": 8-12 surprising-but-true rule facts, each ≥ 20 chars, no
  "Did you know" prefix.
- "voices": 6-8 invented narrator personas themed to the game:
  {"label" (invented character, NEVER a real person/celebrity/existing IP
  character name), "emoji", "style" (≤ 300 chars: TONE ONLY — voice, diction,
  mood. Never ask for footnotes, asides, tangents, rambling, over-explaining,
  "what-ifs", or anything that alters content/numbers; end with "Brief." The
  restyle keeps the rule and length, the persona only colours the wording.
  e.g. "A jittery plague-town apothecary: quick nervous asides of tone, plain
  rule. Brief."), "description" (≤ 100
  chars), "loading_phrases" (6-10 short in-character lines shown while
  thinking), "thanks_phrases" (4-6 short lines)}.
- "first_player": 10-15 fun first-player picks, each ≥ 12 chars, themed.
- "common_mistakes": 5-8 {"wrong", "right"} (each ≥ 12 chars); "right" must be
  a rule the book states.
- "quiz": 12-20 {"q", "choices": [3 str], "answer": 0-based int, "why"}; the
  correct choice must be explicitly stated in the book; vary answer positions.
- "teach": {"goal", "loop", "win", "trap"} — a 60-second teach, one or two
  sentences each ("trap" = the rule new players most often miss).
- "score": [{"label" ≤ 40 chars, "hint"}] for each way to score points at game
  end; [] if the game has no points (co-op / last-standing).
- "turn": 2-8 phases {"name", "note", "actions": [{"label", "rule"}]} in order.

## answers — one for EVERY suggested question

{"question": exactly the suggestion string, "answer": str, "verdict": str,
 "citations": [{"quote": str, "page": int}, ...]}

- Answer like a sharp rules referee: first sentence settles it; 1-4 sentences;
  exact numbers/conditions; name the exception if one applies. For a yes/no
  question start with "Yes," / "No,". Plain text, no markdown headings.
- verdict: "legal"/"illegal" ONLY for a yes/no question (legal = yes/allowed,
  illegal = no/not allowed); "info" for what/how/when/why questions and for any
  question phrased negatively ("is there a penalty…", "can't I…").
  (Don't write suggestions the book can't answer.)
- citations: 1-3, each a VERBATIM contiguous excerpt (10-30 words) of ONE
  page's "text", copied exactly (same words; punctuation/case may differ),
  that directly supports the answer. "page" = that page's "printed" number, or
  its "sheet" if printed is null. Prefer the decisive rule sentence over flavor.

## Self-check before finishing (required)

Run a python check over your file: every citation quote, normalized (lowercase,
non-alphanumerics → single space, trimmed), must be a substring of the
normalized text of the page whose printed (or sheet) == "page". Every
suggestion question must have exactly one answer. Fix anything that fails.
Also json.load the file. Report: counts per section + any answer you were
unsure of. Do not paste the content in your reply.

## Limits the importer enforces
cheat_sheet 1-10000 chars (aim ≤ 8000) · voices ≤ 12 (style ≤ 300 here) · score ≤ 12
(label ≤ 40) · turn ≤ 10 phases, 1-12 actions each · teach keys goal/loop/win/trap
only, each ≥ 8 chars · symbols ≤ 120 · verdicts legal/illegal/info (the importer also
accepts "silent"; don't use it).

## Expansion games (when your task says the game is an expansion)
- Write the FULL enrichment set above for the expansion's own book, PLUS
  "expansion_delta": {"components": [str], "setup": [{"title","detail"}],
  "rules": [str]} — what the expansion ADDS or CHANGES vs the base game, each item
  from the expansion book. Only those three keys; not all empty. Example:
  templates/expansion_delta.example.json. Never write "theme" for an expansion
  (it inherits the base game's; the importer rejects it).
- Answers imported ON the expansion game may cite ONLY the expansion's own pages.
  Rulings that need base + expansion text together go in a separate file imported
  onto the BASE game with "expansions": [EXPANSION_GAME_ID]; those citations may
  quote either book (give the author both page files; page keys must not collide).
