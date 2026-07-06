#!/usr/bin/env bash
# CwdChanged + SessionStart hook: prepare a fresh worktree for development.
#
# Fires whenever the session's cwd changes (EnterWorktree mid-session) or a
# session starts (covers sessions that begin inside a worktree); only acts
# when the relevant cwd is a worktree under .claude/worktrees that hasn't
# been set up yet. Native
# EnterWorktree creation applies worktree.symlinkDirectories itself, but
# manually created worktrees (git worktree add) don't get them, so this
# script also creates any missing symlinks. Then it copies untracked env
# files from the main checkout and fetches deps + compiles so the worktree
# is immediately usable. Progress is logged to tmp/worktree-setup.log.
#
# NOTE: do NOT wire this script to the WorktreeCreate hook. Configuring any
# WorktreeCreate hook switches Claude Code to hook-delegated worktree
# creation: the hook itself must create the worktree and print its path to
# stdout, and native creation (branching + symlinkDirectories) is skipped.
set -u

input=$(cat)
wt=$(printf '%s' "$input" | jq -r '.new_cwd // .cwd // empty')
case "$wt" in
  */.claude/worktrees/*) ;;
  *) exit 0 ;;
esac
[ -d "$wt" ] || exit 0

main_root=$(cd "$(dirname "$(git -C "$wt" rev-parse --git-common-dir)")" && pwd)
mkdir -p "$wt/tmp"

# Run at most once per worktree; mkdir is atomic so concurrent fires lose.
mkdir "$wt/tmp/.worktree-setup-lock" 2>/dev/null || exit 0
log="$wt/tmp/worktree-setup.log"

{
  echo "== worktree setup: $wt"
  echo "== main checkout:  $main_root"
  echo "== started: $(date)"

  # Symlink big shared dirs if native creation didn't already. When the
  # directory already exists in the worktree because it holds tracked files
  # (e.g. priv/browser/install.sh), a whole-dir symlink is impossible — both
  # here and in native symlinkDirectories — so symlink its missing children
  # individually (e.g. the chrome/chromedriver bundles Wallaby needs).
  jq -r '.worktree.symlinkDirectories[]?' "$main_root/.claude/settings.json" 2>/dev/null |
    while IFS= read -r d; do
      [ -e "$main_root/$d" ] || continue
      if [ ! -e "$wt/$d" ]; then
        mkdir -p "$wt/$(dirname "$d")"
        ln -s "$main_root/$d" "$wt/$d" && echo "symlinked $d"
      elif [ -d "$wt/$d" ] && [ ! -L "$wt/$d" ]; then
        for child in "$main_root/$d"/* "$main_root/$d"/.[!.]*; do
          [ -e "$child" ] || continue
          base=$(basename "$child")
          if [ ! -e "$wt/$d/$base" ]; then
            ln -s "$child" "$wt/$d/$base" && echo "symlinked $d/$base"
          fi
        done
      fi
    done

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
