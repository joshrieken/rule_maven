#!/usr/bin/env python3
"""Completeness audit: diff one game against its Ready peers across EVERYTHING
the database stores for a game, so an import can't silently miss an artifact.

usage: python3 -I audit.py GAME_ID [--db DB (default $PGDATABASE or rule_maven_dev)] [--na "LABEL=reason" ...]

Peers = other playable games of the same kind (base vs expansion). Auto-discovers:
  * every column of games (null/empty here, filled on most peers)
  * every table with a game_id / base_game_id / expansion_id column (row counts)
  * every table that FKs to documents or questions_log (rows reached via this game)
  * column fill-rate of questions_log, documents, game_symbols (sparse here vs peers)
  * app_settings keys mentioning a peer's id pattern (per-game settings)
User-activity tables are skipped. Exit 1 if any GAP. A GAP is a lead, not proof:
decide whether it's missing work (fix it) or legitimately N/A (say why).
"""
import json, os, statistics, subprocess, sys

args = sys.argv[1:]
db = os.environ.get("PGDATABASE", "rule_maven_dev")  # "rulemaven" inside the prod tools container
if "--db" in args:
    i = args.index("--db"); db = args[i + 1]; del args[i:i + 2]
na_cli = {}
while "--na" in args:   # --na "symbols with icons=icon-free book"
    i = args.index("--na"); lab, _, why = args[i + 1].partition("="); na_cli[lab] = why or "N/A per operator"; del args[i:i + 2]
gid = int(args[0])

def q(sql):
    r = subprocess.run(["psql", "-d", db, "-At", "-F", "\t", "-c", sql], capture_output=True, text=True)
    if r.returncode: sys.exit(f"SQL failed: {sql}\n{r.stderr}")
    out = r.stdout
    return [l.split("\t") for l in out.splitlines() if l]

SKIP = {"llm_logs", "llm_savings", "mastery_events", "persona_events", "user_collections",
        "user_favorites", "game_support_requests", "game_mastery", "expansion_selections",
        "house_rules", "user_page_coverages", "question_votes", "question_flags", "answer_favorites",
        "question_mismatch_reports", "oban_jobs"}
SKIP_COLS = {"id", "inserted_at", "updated_at", "taken_down_at", "takedown_reason",
             "takedown_complainant", "playable_at"}

is_exp = lambda g: f"exists(select 1 from game_expansion_links where expansion_id={g})"
kind = q(f"select {is_exp(gid)}")[0][0]
peers = [int(r[0]) for r in q(
    f"select id from games g where playable and id<>{gid} and "
    f"exists(select 1 from game_expansion_links where expansion_id=g.id) = {'true' if kind == 't' else 'false'}")]
if not peers:
    sys.exit("no Ready peers of the same kind to compare against")
print(f"game {gid} ({'expansion' if kind == 't' else 'base'}) vs {len(peers)} Ready peers: {peers}\n")
ids = ",".join(map(str, peers + [gid]))
gaps = []
# Known legitimately-N/A findings (reason shown instead of a GAP). Add here ONLY
# after confirming in code that the artifact is optional/history, with the reason.
KNOWN_NA = {
    "documents.source_url fill": "optional; user-supplied PDFs have no public URL",
    "app_settings prep_reset_at_{id}": "history stamp written by reset_prepared",
    "game_symbols.image_note fill": "only written for {n}-family tokens",
}
KNOWN_NA.update(na_cli)

def gap(label, msg):
    if label in KNOWN_NA: print(f"N/A   {label}: {KNOWN_NA[label]}")
    else: gaps.append(label); print(msg)

def judge(label, mine, theirs, sparse=0.5):
    filled = [t for t in theirs if t > 0]
    med = statistics.median(theirs) if theirs else 0
    if len(filled) >= max(1, len(theirs) * 0.5) and mine == 0:
        gap(label, f"GAP   {label}: 0 here; peers median {med:g} ({len(filled)}/{len(theirs)} non-zero)")
    elif med and mine < med * sparse and mine < med and len(filled) == len(theirs):
        print(f"LOW   {label}: {mine:g} here vs peers median {med:g}")

# 1. games columns
cols = [r[0] for r in q("select column_name from information_schema.columns where table_name='games' and table_schema='public'")]
for c in cols:
    if c in SKIP_COLS: continue
    rows = dict((int(a), b == "t") for a, b in q(
        f"select id, ({c} is not null and {c}::text not in ('', '{{}}', '[]', 'false')) from games where id in ({ids})"))
    judge(f"games.{c}", int(rows[gid]), [int(rows[p]) for p in peers])

# 2. game-keyed tables
for t, c in q("select table_name, column_name from information_schema.columns where table_schema='public' "
              "and column_name in ('game_id','base_game_id','expansion_id') order by 1,2"):
    if t in SKIP: continue
    cnt = dict((int(a), int(b)) for a, b in q(f"select {c}, count(*) from {t} where {c} in ({ids}) group by 1"))
    judge(f"{t}.{c} rows", cnt.get(gid, 0), [cnt.get(p, 0) for p in peers])

# 3. tables hanging off documents / questions_log
for t, c, parent in q("""select tc.table_name, kcu.column_name, ccu.table_name from information_schema.table_constraints tc
  join information_schema.key_column_usage kcu on kcu.constraint_name=tc.constraint_name
  join information_schema.constraint_column_usage ccu on ccu.constraint_name=tc.constraint_name
  where tc.constraint_type='FOREIGN KEY' and ccu.table_name in ('documents','questions_log') and tc.table_name<>ccu.table_name"""):
    if t in SKIP: continue
    cnt = dict((int(a), int(b)) for a, b in q(
        f"select p.game_id, count(*) from {t} x join {parent} p on p.id=x.{c} where p.game_id in ({ids}) group by 1"))
    judge(f"{t} (via {parent}.{c}) rows", cnt.get(gid, 0), [cnt.get(p, 0) for p in peers])

# 4. column fill rates on per-game child tables
for t in ("questions_log", "documents", "game_symbols"):
    tcols = [r[0] for r in q(f"select column_name from information_schema.columns where table_name='{t}' and table_schema='public' and data_type not in ('USER-DEFINED')")]
    for c in tcols:
        if c in SKIP_COLS or c == "game_id": continue
        rows = q(f"select game_id, avg(case when {c} is not null and {c}::text not in ('', '{{}}', '[]') then 1.0 else 0 end) "
                 f"from {t} where game_id in ({ids}) group by 1")
        fill = dict((int(a), float(b)) for a, b in rows)
        if gid not in fill: continue
        theirs = [fill[p] for p in peers if p in fill]
        if not theirs: continue
        med = statistics.median(theirs)
        if med >= 0.5 and fill[gid] < 0.1:
            gap(f"{t}.{c} fill", f"GAP   {t}.{c}: {fill[gid]:.0%} filled here vs peers median {med:.0%}")
        elif med >= 0.5 and fill[gid] < med * 0.5:
            print(f"LOW   {t}.{c}: {fill[gid]:.0%} filled here vs peers median {med:.0%}")

# 5. per-game app_settings keys (e.g. "...:<id>" / "..._<id>")
# only keys whose value means something (null / "" / "off" are residue of resets / auto-pilot)
keys = [r[0] for r in q("select key from app_settings where value is not null and value::text not in ('', '\"\"', 'off', '\"off\"', 'null')")]
def norm(k, g):
    import re
    return re.sub(rf"(?<![0-9]){g}(?![0-9])", "{id}", k)
pk = {}
for p in peers:
    for k in keys:
        n = norm(k, p)
        if n != k: pk.setdefault(n, set()).add(p)
mine = {norm(k, gid) for k in keys if norm(k, gid) != k}
for n, ps in sorted(pk.items()):
    if len(ps) >= len(peers) * 0.5 and n not in mine:
        gap(f"app_settings {n}", f"GAP   app_settings key {n}: on {len(ps)}/{len(peers)} peers, missing here")

# 6. invariants a Ready game must satisfy (quality, not just presence)
import re as _re
print("\ninvariants:")
def inv(label, ok, detail=""):
    if not ok and label in KNOWN_NA:
        print(f"N/A   {label}: {KNOWN_NA[label]}"); return
    print(f"{'ok   ' if ok else 'FAIL '} {label}{(' — ' + detail) if detail else ''}")
    if not ok: gaps.append(label)
one = lambda sql: q(sql)[0][0] if q(sql) else None
inv("playable", one(f"select playable from games where id={gid}") == "t")
inv("Prepare auto-pilot OFF", one(f"select count(*) from app_settings where key='readiness_auto_{gid}' and value::text like '%on%'") == "0",
    "auto-pilot would run the app's paid enrichment workers — Readiness.stop_auto / Prepare page Auto off")
r = q(f"select count(*), count(*) filter (where status='published') from documents where game_id={gid}")[0]
inv("all documents published", int(r[0]) > 0 and r[0] == r[1],
    f"{r[1]}/{r[0]} — pending_review docs (short/low-prose text) are invisible to retrieval; publish them")
if kind != "t":
    n = int(one(f"select coalesce(jsonb_array_length(theme_names::jsonb->'sets'),0) from games where id={gid}") or 0)
    inv("theme sets >= 3", n >= 3, f"{n} sets (legacy single palette has 0) — hand-pick from BGG cover")
    inv("BGG weight set", one(f"select weight is not null from games where id={gid}") == "t", "re-run BGG.enrich_game(force: true)")
    xml = one(f"select regexp_replace(coalesce(bgg_data,''), E'[\\n\\r\\t]+', ' ', 'g') from games where id={gid}") or ""
    listed = {int(m) for m, inbound in _re.findall(r'<link type="boardgameexpansion" id="(\d+)"[^>]*?(?:inbound="(true)")?[^>]*/>', xml) if not inbound}
    if listed:
        in_cat = {int(r[0]) for r in q(f"select id from games where bgg_id in ({','.join(map(str, listed))})")}
        linked = {int(r[0]) for r in q(f"select expansion_id from game_expansion_links where base_game_id={gid}")}
        miss = in_cat - linked
        inv("catalog expansions linked", not miss, f"{len(linked)} linked, {len(miss)} in catalog but unlinked → BGG.relink_from_cache")
else:
    inv("linked to a base game", one(f"select count(*) from game_expansion_links where expansion_id={gid}") != "0")
    inv("expansion_delta present", one(f"select count(*) from app_settings where key='delta_content_{gid}' and value is not null") != "0",
        "add expansion_delta to enrichments")
r = q(f"""select count(*), count(*) filter (where pooled and citation_valid and not refused and question_embedding is not null)
          from questions_log where game_id={gid} and llm_provider = 'manual'""")[0]
inv("imported answers pooled+valid+embedded", int(r[0]) > 0 and r[0] == r[1], f"{r[1]}/{r[0]}")
for qid, qq in q(f"select id, left(question,90) from questions_log where game_id={gid} and refused and coalesce(llm_provider,'') not in ('manual','pool') order by id"):
    print(f"info  live ask refused #{qid}: {qq}  (coverage lead: add a prefill answer if the book covers it)")
r = q(f"select count(*), count(*) filter (where c.embedding is not null) from chunks c join documents d on d.id=c.document_id where d.game_id={gid}")[0]
inv("chunks embedded", int(r[0]) > 0 and r[0] == r[1], f"{r[1]}/{r[0]}")
sc = [c[0] for c in q("select column_name from information_schema.columns where table_name='game_symbols' and column_name in ('image','image_data','image_path','image_binary')")]
if sc:
    r = q(f"select count(*), count({sc[0]}) from game_symbols where game_id={gid}")[0]
    inv("symbols with icons", int(r[0]) > 0 and r[0] == r[1], f"{r[1]}/{r[0]} (0 symbols is OK only for an icon-free book)")

print(f"\n{len(gaps)} GAP(s)")
sys.exit(1 if gaps else 0)
