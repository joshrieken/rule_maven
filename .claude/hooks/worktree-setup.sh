#!/usr/bin/env bash
# WorktreeCreate hook: prepare a fresh worktree for development.
# Copies untracked env files from the main checkout, then fetches deps and
# compiles so the worktree is immediately usable. Big shared directories
# (deps, node_modules, browser binaries, etc.) are symlinked by the
# worktree.symlinkDirectories setting, not by this script.
set -u

input=$(cat)
wt=$(printf '%s' "$input" | jq -r '.worktree_path // .path // .cwd // empty')
if [ -z "$wt" ] || [ ! -d "$wt" ]; then
  exit 0
fi

main_root=$(dirname "$(git -C "$wt" rev-parse --git-common-dir)")
mkdir -p "$wt/tmp"
log="$wt/tmp/worktree-setup.log"

{
  echo "== worktree setup: $wt"
  echo "== main checkout:  $main_root"
  echo "== started: $(date)"

  for f in .envrc .envrc.local; do
    if [ -f "$main_root/$f" ] && [ ! -e "$wt/$f" ]; then
      cp "$main_root/$f" "$wt/$f" && echo "copied $f"
    fi
  done

  if command -v direnv >/dev/null 2>&1; then
    direnv allow "$wt" 2>/dev/null && echo "direnv allowed"
    run() { direnv exec "$wt" "$@"; }
  else
    run() { "$@"; }
  fi

  cd "$wt" || exit 0
  run mix deps.get 2>&1
  run mix compile 2>&1
  echo "== finished: $(date)"
} >>"$log" 2>&1
