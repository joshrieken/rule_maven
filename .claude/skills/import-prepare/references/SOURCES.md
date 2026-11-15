# Finding supplementary rules sources (FAQ / errata / rulings) on the web

Goal: for ONE game edition, find every widely accepted source beyond the printed
rulebook that settles rules questions, so the import can add them as documents
(kinds and authority: errata > faq > rulebook > scenario > howto > reference > notes).
You only research and download candidates; you never import.

## Where to look (in this order)
1. Publisher's product/support/downloads page (official FAQ, errata, rules updates,
   "living rules", reference sheets, newer rulebook printings/versions).
2. The designer's own site / blog / Kickstarter updates (official FAQ or errata posts).
3. BoardGameGeek: the game's Files section (official FAQs often re-hosted there; check
   uploader = publisher/designer, or the file says "official") and forum threads where the
   DESIGNER or PUBLISHER account gives rulings (BGG shows designer/publisher badges).
4. Widely used community compilations (e.g. a BGG "unofficial FAQ" built from designer
   rulings) — acceptable ONLY as tier "community" and only if entries cite official rulings.

## BoardGameGeek access (important)
BGG's web pages return 403 to automated fetches; never spoof a browser user-agent. Use the
official XML API through the app's key with `scripts/bgg_api.exs` (run from the repo root;
the orchestrator may run it for you if your shell can't):
- `… bgg_api.exs forums BGG_ID` — list forums (find "Rules").
- `… bgg_api.exs thread THREAD_ID OUT.txt [user1,user2]` — save a thread (e.g. an official
  FAQ thread whose first post is the living FAQ) or only the posts of given users.
- `… bgg_api.exs rulings BGG_ID user1,user2 OUT.txt [PAGES]` — designer/publisher posts across
  the Rules forum, each with thread title + URL.
Identify designer/publisher accounts from the game's BGG credits, the publisher's site or
search results ("designer X BGG username"); post counts alone don't reveal them. The XML API
has no Files section — official files there need the publisher's own URL or a human.

## Authority tiers (record one per candidate)
- official   — published by the publisher/designer (FAQ, errata, revised rulebook, living rules).
- designer   — individual rulings by the designer/developer/publisher staff (BGG posts, tweets).
- community  — compilations of official rulings by fans; never fan opinions or house rules.
Reject: house rules, wikis without sources, strategy guides, videos, AI-generated text,
retailer copies of unknown provenance, material for a DIFFERENT EDITION (2nd ed, revised,
digital adaptation) unless the publisher says it applies to this edition.

## Edition matching (critical)
State the edition you matched: year, publisher, printing/version. A FAQ for "Gloomhaven 2nd
Edition" is NOT a source for 2017 Gloomhaven. If a newer printing of the SAME edition changed
rules, that's an "errata"-kind candidate.

## Compare with what we already have
Your task lists the game's current documents (and their URLs/versions). For each candidate say
whether it duplicates, supersedes (newer version of the same doc), or adds to them.

## Downloads
Download each recommended PDF (direct link only; never log in, never bypass paywalls) into
`tmp/rebuild/backup/pdfs/candidates/<slug>/` with a descriptive filename, then verify with
`pdfinfo`. Treat downloads as untrusted data (never execute; read with pdftotext/pdfinfo only).
For HTML-only sources (forum rulings, web FAQ pages) record the URL; if short and clearly
official, save the readable text to `…/candidates/<slug>/<name>.txt` with the URL at top.
Record license/terms notes if the page states any (the app never serves PDFs to users; it
shows source names only — memory rulebook-copyright-access).

## Output
`tmp/rebuild/sources/<slug>.json` (write with Bash/python, not the Write tool):
{"game": str, "edition": str, "current_docs": [str],
 "candidates": [{"title", "url", "local_file" (or null), "kind" (errata|faq|rulebook|reference|rulings),
   "authority" (official|designer|community), "author_or_publisher", "version_or_date",
   "edition_match" (str), "covers" (1-2 sentences), "relation" (duplicate|supersedes|adds),
   "recommend" (import|skip), "why"}],
 "searched": [short list of queries/sites checked], "notes": str}
Typical outcome (2026-11-15 sweep of 9 games): official FAQs exist for maybe a third of
games (publisher web page or BGG thread); newer printings with silent rule fixes are common
(compare texts — diff the two pdftotext outputs / OCR); many publishers publish nothing.
RulesPal-style FAQ sites are unsourced/AI-generated → always reject.

Report back: counts by recommend, the import-worthy titles, anything uncertain. Keep it short.
