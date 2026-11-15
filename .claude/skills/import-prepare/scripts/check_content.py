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
pages = {}   # page key -> [normalized texts]; base+expansion books may share numbers
for f in args[1:]:
    for p in json.load(open(f))["pages"]:
        k = p["printed"] if p["printed"] is not None else p["sheet"]
        pages.setdefault(k, []).append(n(p["text"]))

bad = 0
def fail(*m):
    global bad
    bad += 1
    print(*m)

NEG = re.compile(r"\b(do not|don't|does not|doesn't|cannot|can't|never|instead|skip|only|no longer|not allowed)\b", re.I)
RESTR = re.compile(r"\b(not|no|never|cannot|only|instead|except|unless|must|may not)\b", re.I)

seen = set()
for a in c.get("answers", []):
    q = n(a["question"])
    if q in seen: fail("DUP QUESTION", a["question"])
    seen.add(q)
    if a.get("verdict") not in ("legal", "illegal", "info"): fail("VERDICT", a["question"])
    if not 1 <= len(a["citations"]) <= 3: fail("CIT COUNT", a["question"])
    for ct in a["citations"]:
        w = len(n(ct["quote"]).split())
        if not 10 <= w <= 30: fail("WORDS", w, ct["quote"][:60])
        if not any(n(ct["quote"]) in t for t in pages.get(ct["page"], [])): fail("MISS p", ct["page"], ct["quote"][:70])
    if NEG.search(a["answer"]) and not any(RESTR.search(ct["quote"]) for ct in a["citations"]):
        fail("UNSUPPORTED NEGATIVE", a["question"])

if not prefill and "enrichments" in c:
    e = c["enrichments"]
    qs = [q for s in e["suggestions"] for q in s["questions"]]
    aq = [a["question"] for a in c.get("answers", [])]
    for q in qs:
        if aq.count(q) != 1: fail("ANSWER COUNT", aq.count(q), q)
    if len(e["cheat_sheet"]) > 8000: fail("CHEAT SHEET TOO LONG", len(e["cheat_sheet"]))
    for v in e["voices"]:
        if len(v["style"]) > 300 or len(v["description"]) > 100 or not v["style"].endswith("Brief."):
            fail("VOICE", v["label"])
    for qz in e["quiz"]:
        if not 0 <= qz["answer"] < 3: fail("QUIZ ANSWER", qz["q"])
    print({k: (len(v) if not isinstance(v, (int, float)) else v) for k, v in e.items()})

# importer limits (lib/rule_maven/manual_import/enrichments.ex) — for any keys present
e = c.get("enrichments", {})
str_ = lambda x: isinstance(x, str) and x.strip() != ""
if "score" in e and (len(e["score"]) > 12 or any(len(x.get("label", "")) > 40 or not str_(x.get("hint")) for x in e["score"])):
    fail("SCORE: <=12 entries, label <=40 chars, hint required")
if "turn" in e and (not 1 <= len(e["turn"]) <= 10 or any(not 1 <= len(ph.get("actions", [])) <= 12 for ph in e["turn"])):
    fail("TURN: 1-10 phases, each 1-12 actions")
if "teach" in e and (set(e["teach"]) - {"goal", "loop", "win", "trap"} or any(len(v) < 8 for v in e["teach"].values())):
    fail("TEACH: keys goal/loop/win/trap only, each >=8 chars")
if "voices" in e and len(e["voices"]) > 12: fail("VOICES: <=12")
if "common_mistakes" in e and len(e["common_mistakes"]) > 8: fail("COMMON_MISTAKES: <=8")
if "quiz" in e and len(e["quiz"]) > 20: fail("QUIZ: <=20")
for k in ("suggestions", "did_you_know", "first_player", "common_mistakes", "quiz", "teach", "score", "turn", "setup", "expansion_delta"):
    if k in e and len(json.dumps(e[k], ensure_ascii=False, separators=(",", ":"))) > 10000:
        fail(f"{k.upper()}: stored JSON > 10000 chars (app_settings cap) — trim")
if "cheat_sheet" in e and len(e["cheat_sheet"]) > 10000: fail("CHEAT SHEET > 10000 (hard cap)")
if "symbols" in e and len(e["symbols"]) > 120: fail("SYMBOLS: <=120")
if "expansion_delta" in e:
    d = e["expansion_delta"]
    if set(d) - {"components", "setup", "rules"}: fail("DELTA: only components/setup/rules keys")
    if not any(d.get(k) for k in ("components", "setup", "rules")): fail("DELTA: all empty")
    if not all(str_(x) for x in d.get("components", []) + d.get("rules", [])): fail("DELTA: components/rules must be non-empty strings")
    if not all(str_(x.get("title")) and str_(x.get("detail")) for x in d.get("setup", [])): fail("DELTA: setup items need title+detail")
if "theme" in e:
    for st in e["theme"].get("sets", []):
        for mode in ("light", "dark"):
            if set(st.get(mode, {})) != {"accent", "bg", "surface", "text"}: fail(f"THEME: {mode} needs accent/bg/surface/text")
        if not (str_(st.get("names", {}).get("light")) and str_(st.get("names", {}).get("dark"))): fail("THEME: names.light/dark")
    if not 3 <= len(e["theme"].get("sets", [])) <= 5: fail("THEME: 3-5 sets")
print("answers", len(c.get("answers", [])), "bad", bad)
sys.exit(1 if bad else 0)
