#!/usr/bin/env python3
"""Validate a Prepare content / prefill JSON against its transcription(s).

usage: python3 -I check_content.py CONTENT.json PAGES.json [PAGES2.json ...]
       (--prefill for a prefill file: answers only, no enrichments/suggestion match)

Pages from several documents (rulebook + FAQ) are keyed by printed page (else
sheet); keys must not collide across documents.
"""
import json, re, sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
prefill = "--prefill" in sys.argv
c = json.load(open(args[0]))
n = lambda s: re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()
pages = {}
for f in args[1:]:
    for p in json.load(open(f))["pages"]:
        k = p["printed"] if p["printed"] is not None else p["sheet"]
        if k in pages:
            print("PAGE KEY COLLISION", k, f)
        pages[k] = n(p["text"])

bad = 0
def fail(*m):
    global bad
    bad += 1
    print(*m)

NEG = re.compile(r"\b(do not|don't|does not|doesn't|cannot|can't|never|instead|skip|only|no longer|not allowed)\b", re.I)
RESTR = re.compile(r"\b(not|no|never|cannot|only|instead|except|unless|must|may not)\b", re.I)

seen = set()
for a in c["answers"]:
    q = n(a["question"])
    if q in seen: fail("DUP QUESTION", a["question"])
    seen.add(q)
    if a.get("verdict") not in ("legal", "illegal", "info"): fail("VERDICT", a["question"])
    if not 1 <= len(a["citations"]) <= 3: fail("CIT COUNT", a["question"])
    for ct in a["citations"]:
        w = len(n(ct["quote"]).split())
        if not 10 <= w <= 30: fail("WORDS", w, ct["quote"][:60])
        if n(ct["quote"]) not in pages.get(ct["page"], ""): fail("MISS p", ct["page"], ct["quote"][:70])
    if NEG.search(a["answer"]) and not any(RESTR.search(ct["quote"]) for ct in a["citations"]):
        fail("UNSUPPORTED NEGATIVE", a["question"])

if not prefill and "enrichments" in c:
    e = c["enrichments"]
    qs = [q for s in e["suggestions"] for q in s["questions"]]
    aq = [a["question"] for a in c["answers"]]
    for q in qs:
        if aq.count(q) != 1: fail("ANSWER COUNT", aq.count(q), q)
    if len(e["cheat_sheet"]) > 8000: fail("CHEAT SHEET TOO LONG", len(e["cheat_sheet"]))
    for v in e["voices"]:
        if len(v["style"]) > 300 or len(v["description"]) > 100 or not v["style"].endswith("Brief."):
            fail("VOICE", v["label"])
    for qz in e["quiz"]:
        if not 0 <= qz["answer"] < 3: fail("QUIZ ANSWER", qz["q"])
    print({k: (len(v) if not isinstance(v, (int, float)) else v) for k, v in e.items()})
print("answers", len(c["answers"]), "bad", bad)
sys.exit(1 if bad else 0)
