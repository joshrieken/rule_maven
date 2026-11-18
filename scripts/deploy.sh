#!/usr/bin/env bash
# Update the production server: back up the database, pull, rebuild, swap containers with no gap.
# Run on the server from the checkout (/opt/rulemaven):
#   ./scripts/deploy.sh            latest master
#   ./scripts/deploy.sh <commit>   a specific commit (rolling back)
# Only releases deploy: the commit must be a "Release vX.Y.Z" commit whose VERSION file says that
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
    # A full commit hash (what autodeploy passes, after checking its signature) is always that commit, never
    # a branch someone named after it.
    if [[ ! $target_ref =~ ^[0-9a-f]{40}$ ]] && git show-ref --verify --quiet "refs/remotes/origin/$target_ref"; then
      target_ref="origin/$target_ref"
    fi
  fi
  local target subject version
  target=$(git rev-parse --verify --quiet "${target_ref:-origin/$BRANCH}^{commit}") || { echo "No such commit: ${target_ref:-origin/$BRANCH}" >&2; exit 1; }
  subject=$(git log -1 --format=%s "$target")
  version=$(git show "$target:VERSION" 2>/dev/null | tr -d '[:space:]')
  if ! [[ "$subject" =~ ^Release\ v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || [ "${BASH_REMATCH[1]}" != "$version" ]; then
    echo "Not deploying $(git log -1 --format='%h %s' "$target")" >&2
    echo "Only release commits deploy: \"Release vX.Y.Z\" with VERSION at that version." >&2
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
    git checkout --quiet --detach "$target"
  else
    git checkout --quiet "$BRANCH"
    git merge --ff-only --quiet "origin/$BRANCH"
  fi
  [ "$(git rev-parse HEAD)" = "$target" ] || { echo "Checked out $(git rev-parse HEAD), expected $target" >&2; exit 1; }
  git log --oneline -1

  echo "== Building"
  "${COMPOSE[@]}" build

  # Rolling swap: start the new container BESIDE the running one, wait until Traefik can route to
  # it (Docker says healthy, and it reports the version just built), then retire the old one.
  # Visitors never hit a gap. For those seconds both versions serve and the new one has already
  # migrated, so migrations must stay backward-compatible (add, don't rename/drop, in one release).
  echo "== Starting v$version beside the running version"
  "${COMPOSE[@]}" up -d --remove-orphans db
  local old new
  old=$("${COMPOSE[@]}" ps -q "$SVC" 2>/dev/null || true)
  if [ -z "$old" ]; then
    "${COMPOSE[@]}" up -d --no-deps "$SVC"
  else
    "${COMPOSE[@]}" up -d --no-deps --no-recreate --scale "$SVC=2" "$SVC"
  fi
  new=$("${COMPOSE[@]}" ps -q "$SVC" | grep -vxF "${old:-none}" | head -1 || true)
  [ -n "$new" ] || { echo "The new container didn't start." >&2; exit 1; }

  echo "== Waiting for v$version to be healthy"
  local running="" health=""
  for _ in $(seq 1 180); do
    running=$(docker exec "$new" curl -fsS http://127.0.0.1:4000/health 2>/dev/null \
      | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' || true)
    health=$(docker inspect -f '{{.State.Health.Status}}' "$new" 2>/dev/null || true)
    [ "$running" = "$version" ] && [ "$health" = healthy ] && break
    [ "$(docker inspect -f '{{.State.Running}}' "$new" 2>/dev/null)" = true ] || break
    sleep 1
  done
  if [ "$running" != "$version" ] || [ "$health" != healthy ]; then
    echo "v$version didn't become healthy (answering: ${running:-nothing}, health: ${health:-none})." >&2
    echo "The previous version keeps serving. Logs of the new container:" >&2
    docker logs --tail 60 "$new" >&2 || true
    docker rm -f "$new" >/dev/null
    exit 1
  fi

  if [ -n "$old" ]; then
    echo "== Retiring the previous version"
    # A moment for Traefik to route to the new container (it reloads at most every 2 s), then stop the old
    # one; anything still reaching it as it shuts down is retried on the new one (retry middleware).
    sleep 2
    # By id, never a compose scale-down: that removes the highest-numbered replica, which may
    # be the new one.
    docker stop -t 30 "$old" >/dev/null && docker rm "$old" >/dev/null
  fi

  echo "== Seeding new feature flags"
  docker exec "$new" bin/rule_maven rpc \
    'Enum.each(RuleMaven.Flags.seed_missing(), &IO.puts("seeded flag #{&1.id} = #{&1.default}"))'
  local host
  host=$({ grep -E '^RULEMAVEN_HOST=' .env || true; } | head -1 | cut -d= -f2-)
  echo "Up: v$version at https://${host:-(set RULEMAVEN_HOST in .env)}"
  docker image prune -f --filter "label=com.docker.compose.project=$(basename "$PWD")" >/dev/null
}

main "$@"
exit
