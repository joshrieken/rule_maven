#!/usr/bin/env python3
"""Merge prefill part files, dropping questions that duplicate each other, the
game's suggested answers, or questions already in the DB.

usage: python3 -I merge_prefill.py OUT.json PART.json [PART.json ...] \
          [--content content/<slug>.json] [--existing prefill/existing/<slug>.txt]
Exact-normalized dedupe only; near-duplicates (same ruling, other words) are
listed as WARN pairs (shared-token Jaccard >= 0.8) for a manual look.
"""
import json, re, sys

argv = sys.argv[1:]
def opt(name):
    if name in argv:
        i = argv.index(name); v = argv[i + 1]; del argv[i:i + 2]; return v
content, existing = opt("--content"), opt("--existing")
out, parts = argv[0], argv[1:]
n = lambda s: re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()
seen = set()
if content:
    seen |= {n(a["question"]) for a in json.load(open(content))["answers"]}
if existing:
    seen |= {n(l) for l in open(existing) if l.strip()}
kept, dropped = [], 0
for p in parts:
    for a in json.load(open(p))["answers"]:
        k = n(a["question"])
        if k in seen: dropped += 1; continue
        seen.add(k); kept.append(a)
toks = [set(n(a["question"]).split()) for a in kept]
for i in range(len(kept)):
    for j in range(i + 1, len(kept)):
        u = toks[i] | toks[j]
        if u and len(toks[i] & toks[j]) / len(u) >= 0.8:
            print("WARN near-dup:", kept[i]["question"], "||", kept[j]["question"])
json.dump({"answers": kept}, open(out, "w"), indent=1, ensure_ascii=False)
print("kept", len(kept), "dropped", dropped)
