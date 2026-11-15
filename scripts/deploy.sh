#!/usr/bin/env bash
# Update the production server: back up the database, pull, rebuild, restart.
# Run on the server from the checkout (/opt/rulemaven):
#   ./scripts/deploy.sh            latest master
#   ./scripts/deploy.sh <commit>   a specific commit (rolling back)
# Only releases deploy: the commit must be a "Release vX.Y.Z" commit whose mix.exs says that
# version, so what runs always has a version and a changelog entry.
# Migrations run when the new container starts; the backup taken first is the way back. To roll back:
#   docker compose stop rulemaven
#   docker compose exec -T db pg_restore -U rulemaven -d rulemaven --clean --if-exists < data/backups/<backup>.dump
#   ./scripts/deploy.sh <previous release commit>
# (Adapted from Drawburn's / Stir & Fold's deploy script.)
#
# Everything is inside main, which bash reads whole before running it: the checkout below may change
# this file, and bash otherwise reads a script as it goes.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  local COMPOSE=(docker compose)
  local KEEP=14 SVC=rulemaven BRANCH=master

  echo "== Checking it's a release"
  git fetch --quiet origin
  local target_ref=""
  if [ -n "${1:-}" ]; then
    target_ref=$1
    git show-ref --verify --quiet "refs/remotes/origin/$target_ref" && target_ref="origin/$target_ref"
  fi
  local target subject version
  target=$(git rev-parse --verify --quiet "${target_ref:-origin/$BRANCH}^{commit}") || { echo "No such commit: ${target_ref:-origin/$BRANCH}" >&2; exit 1; }
  subject=$(git log -1 --format=%s "$target")
  version=$(git show "$target:mix.exs" | sed -n 's/^ *version: "\([^"]*\)".*/\1/p' | head -1)
  if ! [[ "$subject" =~ ^Release\ v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || [ "${BASH_REMATCH[1]}" != "$version" ]; then
    echo "Not deploying $(git log -1 --format='%h %s' "$target")" >&2
    echo "Only release commits deploy: \"Release vX.Y.Z\" with mix.exs at that version." >&2
    exit 1
  fi
  echo "v$version ($(git log -1 --format=%h "$target"))"

  echo "== Backing up the database"
  mkdir -p data/backups data/files
  chmod 700 data/backups
  local stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  if [ -n "$("${COMPOSE[@]}" ps -q db 2>/dev/null || true)" ]; then
    # Backups hold every account and the LLM API keys: owner-only.
    (umask 077 && "${COMPOSE[@]}" exec -T db pg_dump -U rulemaven -Fc rulemaven > "data/backups/rulemaven-$stamp.dump")
    echo "saved data/backups/rulemaven-$stamp.dump"
  else
    echo "(not running yet; skipped)"
  fi
  { ls -1t data/backups/rulemaven-*.dump 2>/dev/null || true; } | tail -n +$((KEEP + 1)) | xargs -r rm -f

  echo "== Getting the code"
  if [ -n "$target_ref" ]; then
    git checkout --quiet --detach "$target_ref"
  else
    git checkout --quiet "$BRANCH"
    git merge --ff-only --quiet "origin/$BRANCH"
  fi
  git log --oneline -1

  echo "== Building"
  "${COMPOSE[@]}" build

  echo "== Restarting"
  "${COMPOSE[@]}" up -d --remove-orphans

  echo "== Waiting for v$version to answer"
  local running host
  for _ in $(seq 1 90); do
    # The new build, not the old container still answering: it must report the version just built.
    running=$("${COMPOSE[@]}" exec -T "$SVC" curl -fsS http://127.0.0.1:4000/health 2>/dev/null \
      | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' || true)
    if [ "$running" = "$version" ]; then
      echo "== Seeding new feature flags"
      "${COMPOSE[@]}" exec -T "$SVC" bin/rule_maven rpc \
        'Enum.each(RuleMaven.Flags.seed_missing(), &IO.puts("seeded flag #{&1.id} = #{&1.default}"))'
      host=$({ grep -E '^RULEMAVEN_HOST=' .env || true; } | head -1 | cut -d= -f2-)
      echo "Up: v$version at https://${host:-(set RULEMAVEN_HOST in .env)}"
      docker image prune -f --filter "label=com.docker.compose.project=$(basename "$PWD")" >/dev/null
      exit 0
    fi
    sleep 2
  done
  echo "v$version didn't come up in 3 minutes (answering: ${running:-nothing}). Recent logs:" >&2
  "${COMPOSE[@]}" logs --tail 60 "$SVC" >&2
  exit 1
}

main "$@"
exit
