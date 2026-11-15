#!/usr/bin/env python3
"""Template: merge transcription parts into per-document page files, normalizing
inline tokens. Copy to tmp/rebuild/<slug>/merge.py, edit CONFIG, run from repo root:
    python3 -I tmp/rebuild/<slug>/merge.py
Output: tmp/rebuild/out/<slug>.json (+ one file per extra document), each
{"label","kind","pdf","source_url","pages":[{sheet,printed,text}]}.
"""
import json, re

# ---------------- CONFIG ----------------
SLUG = "game"
DOCS = [  # one entry per source document; parts listed in sheet order
    {"out": f"tmp/rebuild/out/{SLUG}.json", "label": "Rulebook", "kind": "rulebook",
     "pdf": f"tmp/rebuild/backup/pdfs/{SLUG}.pdf", "source_url": None,
     "parts": ["r1", "r2"], "sheets": 18},
    # {"out": f"tmp/rebuild/out/{SLUG}_faq.json", "label": "Official FAQ", "kind": "faq",
    #  "pdf": f"tmp/rebuild/backup/pdfs/{SLUG}_faq.pdf", "source_url": None,
    #  "parts": ["f1"], "sheets": 10},
]
PARTS_DIR = f"tmp/rebuild/{SLUG}/parts"
# drift → canonical token (from scripts/tokens.py output)
REPLACE = {
    # "[small dot]": "[small round dot]",
}
# printed-number overrides for unnumbered pages that would collide across docs
PRINTED = {
    # ("faq", 29): 81,
}
def page_fix(kind, part, sheet, text):
    """Per-page fixes for token COLLISIONS (same token, two meanings) and
    trimming art inferences. Keep each fix narrow: part + sheet + exact string."""
    # if part == "r4" and sheet in (29, 30): text = re.sub(r"\[black circle: (\d)\]", r"[standee number: \1]", text)
    return text
# ----------------------------------------

keys = []
for d in DOCS:
    pages = []
    for p in d["parts"]:
        for pg in json.load(open(f"{PARTS_DIR}/{p}.json"))["pages"]:
            t = pg["text"]
            for a, b in REPLACE.items(): t = t.replace(a, b)
            pg["text"] = page_fix(d["kind"], p, pg["sheet"], t)
            if (d["kind"], pg["sheet"]) in PRINTED: pg["printed"] = PRINTED[(d["kind"], pg["sheet"])]
            pages.append(pg)
    assert [p["sheet"] for p in pages] == list(range(1, d["sheets"] + 1)), f"{d['out']}: sheets missing/out of order"
    assert all(p["text"].strip() for p in pages), f"{d['out']}: empty page text"
    keys += [p["printed"] if p["printed"] is not None else p["sheet"] for p in pages]
    json.dump({k: d[k] for k in ("label", "kind", "pdf", "source_url")} | {"pages": pages},
              open(d["out"], "w"), indent=1, ensure_ascii=False)
    print(d["out"], len(pages), "pages")
dup = sorted({k for k in keys if keys.count(k) > 1})
assert not dup, f"page keys collide across documents: {dup} — set PRINTED overrides"
print("ok: page keys unique")
