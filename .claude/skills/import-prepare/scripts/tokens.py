#!/usr/bin/env python3
"""Inventory inline bracket tokens across transcription files/parts, with counts
per file, to spot drift between parallel transcribers ("[small dot]" vs
"[small round dot]") and collisions (one token used for two different things).

usage: python3 -I tokens.py FILE.json [FILE.json ...]   # each {"pages":[...]}
"""
import collections, json, re, sys

STRUCT = re.compile(r"\[(Caption|Map legend|Cover|Back cover|Diagram|Card illustration|Illustration|Example|callout|illegible|Board|Printed|QR code|Blank page)", re.I)
c = collections.defaultdict(collections.Counter)
for f in sys.argv[1:]:
    name = f.rsplit("/", 1)[-1]
    for pg in json.load(open(f))["pages"]:
        for t in re.findall(r"\[[^\[\]]{1,80}\]", pg["text"]):
            if not STRUCT.match(t):
                c[t][f"{name}:p{pg['printed'] or pg['sheet']}"] += 1
for t in sorted(c, key=str.lower):
    pages = sorted(c[t])
    print(f"{sum(c[t].values()):4} {t}  {', '.join(pages[:6])}{' …' if len(pages) > 6 else ''}")
