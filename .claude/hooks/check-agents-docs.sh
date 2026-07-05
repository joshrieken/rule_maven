#!/usr/bin/env bash
# Advisory nag: warn (don't block) if a commit touches lib/*.ex without touching .agents/*.md.
set -euo pipefail

staged="$(git diff --cached --name-only 2>/dev/null || true)"

if [ -z "$staged" ]; then
  exit 0
fi

touches_lib=false
touches_agents=false

while IFS= read -r path; do
  case "$path" in
    lib/*.ex) touches_lib=true ;;
    .agents/*.md) touches_agents=true ;;
  esac
done <<< "$staged"

if [ "$touches_lib" = true ] && [ "$touches_agents" = false ]; then
  echo "[check-agents-docs] Staged lib/*.ex changes with no .agents/*.md update." >&2
  echo "[check-agents-docs] New/renamed module, changed public function, or changed data flow? Update .agents/codebase-map.md or .agents/data-flows.md. Otherwise ignore." >&2
fi

exit 0
