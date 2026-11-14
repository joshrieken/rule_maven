#!/bin/zsh
# Usage: import_prefill.sh SLUG GAME_ID [BASE_GAME_ID]
# Imports tmp/rebuild/prefill/SLUG.json answers onto GAME_ID; with BASE_GAME_ID
# (GAME_ID is an expansion) also onto the base game WITH that expansion set.
cd /Users/facto/development/personal/rule_maven
SLUG=$1; GAME=$2; BASE=$3
python3 - "$SLUG" "$GAME" <<'P'
import json, sys
slug, game = sys.argv[1], int(sys.argv[2])
a = json.load(open(f"tmp/rebuild/prefill/{slug}.json"))["answers"]
json.dump({"answers": a}, open(f"tmp/rebuild/prefill/{slug}.import.json", "w"), ensure_ascii=False)
json.dump({"answers": a, "expansions": [game]}, open(f"tmp/rebuild/prefill/{slug}.combo.json", "w"), ensure_ascii=False)
print(slug, len(a), "answers")
P
mix rule_maven.import_content $GAME jrieken tmp/rebuild/prefill/$SLUG.import.json 2>&1 | grep -E ": answers |✗|\*\* \(" | cut -c1-260
if [ -n "$BASE" ]; then
  mix rule_maven.import_content $BASE jrieken tmp/rebuild/prefill/$SLUG.combo.json 2>&1 | grep -E ": answers |✗|\*\* \(" | cut -c1-260
fi
