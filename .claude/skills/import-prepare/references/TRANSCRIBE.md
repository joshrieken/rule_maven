# Rulebook transcription rules

You are transcribing a board-game rulebook PDF, page by page, into text that a
rules-Q&A system will answer from. Accuracy is everything: a wrong word can
change a rule.

Render pages yourself:
  pdftoppm -f N -l N -r 150 -png <PDF> <scratch_dir>/p     # then Read the PNG
If any small text or an inline token is hard to read, re-render just that page
at -r 300 (optionally crop with -x -y -W -H) and read again. Delete PNGs when done.

For EACH page produce {"sheet": <PDF page number>, "printed": <page number printed
on the page, or null if none is printed>, "text": "<transcription>"}.

Transcription rules:
1. Transcribe ALL rule-bearing text verbatim, in natural reading order (column by
   column; a sidebar/callout after the section it belongs to). Keep headings as
   their own lines, in the printed case. Keep numbered/bulleted lists as lists.
2. INLINE TOKENS / GLYPHS inside a sentence: if the glyph has characters printed
   on it, write those characters plus its colour in brackets, e.g.
   "discard [blue token: 6+] to battle Mimic", "roll the d20. [black d20 face: 1]:
   You miss." If it is purely pictorial, describe what it LOOKS like, neutrally:
   "[red shield symbol]", "[yellow book symbol]". NEVER name what a glyph means
   or stands for ("[sword icon]", "[action]", "[frenzy]") unless the rulebook
   itself labels it right there. A printed word is ALWAYS transcribed as the word.
3. Tables: one row per line, cells separated by " | ", header row first.
4. Diagrams / maps / illustrations: include every text label or caption that
   carries a rule or a quest element (e.g. map legend "Vault door", "Objective
   (5 XP)", "Player starting area"), as "[Map legend: …]" / "[Caption: …]" lines.
   Skip purely decorative art. For a scenario/quest map, list its legend entries
   and any labelled tiles.
5. Skip running headers/footers and the bare page number (it goes in "printed").
6. Flavor/story text: keep it (short, italic intros), marked with a leading
   "Flavor: ". It helps retrieval but must not be confused with rules.
7. A page with no rule text (cover, full art, credits-only) still gets a short
   non-empty text, e.g. "[Cover: ZOMBICIDE BLACK PLAGUE — RULES AND QUESTS]" or
   the credits text verbatim.
8. Do not summarise, fix, reword, or add anything. If a word is truly illegible,
   write [illegible].

Output: write a JSON file (exact path given in your task) of the form
  {"label": ..., "kind": "rulebook", "pdf": ..., "source_url": ..., "pages": [ ... ]}
with pages in sheet order. Validate it parses (python3 -c 'import json; json.load(open(F))').
Report back only: pages written, and a list of any pages/spots you were unsure
about (page + what + why). Do not paste the transcription into your reply.

Symbol consistency: write each inline icon with ONE bracket token used
identically everywhere in the book (same colour/shape words every time), and
numbers as digits ("[black triangle: 3]") so families key as "{n}". After
transcribing, build the symbol key per tmp/rebuild/SYMBOLS.md.
