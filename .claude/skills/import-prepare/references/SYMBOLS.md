# Building a game's symbol key

Players ask "what does the purple hammer mean?" — the app answers from a
per-game SYMBOL KEY: one entry per distinct inline symbol the transcription
uses, saying what the BOOK calls it and what it means, plus a cropped icon.

Inputs (paths in your task): the transcription JSON (pages with "sheet",
"printed", "text") and the source PDF.

## 1. Find every symbol token

Inline symbols in the transcription are bracketed descriptions, e.g.
"[purple hammer symbol]", "[blue droplet symbol]", "[black triangle: 3]",
"[red die face: 2 pips]", "[gold coin symbol]". Collect EVERY distinct one
(python over all pages). Ignore structural brackets that are not symbols:
"[Caption: …]", "[Map legend: …]", "[Cover: …]", "[Diagram …]",
"[Board diagram …]", "[Example …]", "[Card illustration: …]",
"[Printed page N]", "[illegible]".

Families that differ only by a number become ONE entry whose token uses
`{n}` for the number: "[black triangle: {n}]", "[red die face: {n} pips]"
(write `{n}` exactly where the digits are; "pip"/"pips" variants need
separate entries if both appear). The token must match the transcription
text character for character apart from `{n}` (case-insensitive is fine).

## 2. Say what the book says it is

For each token, find where the BOOK defines it — a legend, component list,
iconography page, a sentence like "Warrior (red blade)", a label beside the
icon. Fill:

- "name": the book's own name for it ("Blacksmith", "Will counter",
  "black eight-sided die"), or null if the book never names it.
- "meaning": 1-2 sentences, what it means/does in play, using ONLY what the
  book states. If the book never explains it, describe where it appears
  ("Printed on Hunter cards.") — never guess its function.
- "aliases": short words players might use ("hammer", "pickaxe", "d8").
- "page": the page (printed, else sheet) where the book defines/labels it.

Accuracy rules: never name a symbol from game knowledge, other editions or
the internet. Colour+shape descriptions stay as transcribed. If two tokens
are the same symbol written two ways, keep both entries with the same name
and meaning.

## 3. Crop each icon

For each entry, crop ONE clean example of the icon from the PDF:

    pdftoppm -f P -l P -r 300 -png -x X -y Y -W W -H H <PDF> <out_prefix>

(-x/-y/-W/-H are pixels at the chosen -r). Render the page first at low res
to locate it, then crop tight (a few px margin), then Read the PNG to check
it shows exactly that icon. Save as
`tmp/rebuild/symbols/<slug>/<short-kebab-name>.png` and put that relative
path in "image_path". For a `{n}` family, crop one representative (e.g. the
die with 3 pips) and say which in "image_note". If you cannot find a clean
instance, set "image_path": null. Keep crops small (≤ 160 px either side —
downscale with `sips -Z 160 file.png` if needed). Delete scratch renders.

## Output

`tmp/rebuild/symbols/<slug>.json`:

    {"symbols": [{"token", "name", "meaning", "aliases": [..], "page",
                  "image_path", "image_note"?}, ...]}

Self-check (python): json.load; every token (with `{n}` → `\d+`) matches at
least one place in the transcription text; no duplicate tokens; every
image_path exists and is ≤ 160 px. Report: count, which tokens had no book
definition (name null), which had no image, anything unsure. No mix, no DB.
