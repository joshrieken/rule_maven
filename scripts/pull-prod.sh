#!/usr/bin/env bash
# Copy production's data down to this machine's dev setup: the database (into rule_maven_dev on the local
# Postgres) and uploaded files (rulebook PDFs etc., into priv/static/uploads, git-ignored). From your Mac,
# in the repo, with the dev server stopped:
#   ./scripts/pull-prod.sh          (../hub/ops/pull-prod-all.sh runs every app's, identity first)
# Prod is read-only here (pg_dump in the db container, rsync of files). The local database is dumped to
# data/backups/ first. Accounts stay linked by their sign-on id: pull the local Authentik from prod first
# (../identity/scripts/pull-prod.sh). Never copied: sign-in tokens, and credential settings (email, LLM,
# BGG keys...), so nothing local can send email or spend as prod; dev's own values of those are kept.
# Migrations newer than prod run at the end.
set -euo pipefail
{
cd "$(dirname "$0")/.."
SSH_HOST=${LCCZ_SSH:-deploy@207.244.249.148}
REMOTE=/opt/rulemaven
LOCAL_DB=${RULEMAVEN_DEV_DB:-rule_maven_dev}
PGUSER=${PGUSER:-postgres}; export PGUSER PGHOST=${PGHOST:-localhost}
PORT=${DEV_PORT:-4000}
# Settings that are credentials or this machine's own (email/LLM/BGG keys, proxy, the app's address, live
# dev mail): prod's never land here, and dev's survive the pull.
LOCAL_ONLY="key ~ '(api_key|_pass\$|secret|token|password)' OR key IN ('llm_proxy_url', 'public_url', 'mail_dev_live')"

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "The dev server is running (port $PORT). Stop it first." >&2; exit 1
fi
# The dev zone's container (hub/dev) has the same database open: refuse while it runs.
if docker ps -q --filter label=com.docker.compose.project=lccz-dev --filter label=com.docker.compose.service=rulemaven 2>/dev/null | grep -q .; then
  echo "The dev zone's rulemaven container is running: hub/dev/down.sh (or docker compose -f ../hub/dev/compose.yaml stop rulemaven) first." >&2
  exit 1
fi
psql -d postgres -Atqc "select 1" >/dev/null || { echo "Can't reach the local Postgres as $PGUSER@$PGHOST." >&2; exit 1; }

SOCK="$HOME/.ssh/lccz-pull-%C"
SSH=(ssh -o ControlMaster=auto -o "ControlPath=$SOCK" -o ControlPersist=300)
trap '"${SSH[@]}" -O exit "$SSH_HOST" 2>/dev/null || true' EXIT
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p data/backups && chmod 700 data/backups

echo "== Dumping prod's database"
(umask 077 && "${SSH[@]}" "$SSH_HOST" "cd $REMOTE && docker compose exec -T db pg_dump -U rulemaven -Fc rulemaven" > "data/backups/prod-$stamp.dump")
[ -s "data/backups/prod-$stamp.dump" ] || { echo "The dump is empty; nothing changed locally." >&2; exit 1; }

if psql -d postgres -Atqc "select 1 from pg_database where datname = '$LOCAL_DB'" | grep -q 1; then
  echo "== Keeping your local database (data/backups/local-$stamp.dump)"
  (umask 077 && pg_dump -Fc "$LOCAL_DB" > "data/backups/local-$stamp.dump")
  (umask 077 && psql -d "$LOCAL_DB" -Atqc "COPY (SELECT key, value, inserted_at, updated_at FROM app_settings WHERE $LOCAL_ONLY) TO STDOUT" > "data/backups/local-settings-$stamp.tsv" 2>/dev/null) || : > "data/backups/local-settings-$stamp.tsv"
fi

echo "== Restoring into $LOCAL_DB"
psql -q -d postgres -c "DROP DATABASE IF EXISTS \"$LOCAL_DB\" WITH (FORCE);" -c "CREATE DATABASE \"$LOCAL_DB\";"
# (--no-owner/--no-acl: prod's roles don't exist here. pgvector etc. come from the dump's CREATE EXTENSION.)
pg_restore -d "$LOCAL_DB" --no-owner --no-acl "data/backups/prod-$stamp.dump" 2> "data/backups/restore-$stamp.log" || {
  grep -v "^$" "data/backups/restore-$stamp.log" | grep -vi "warning: errors ignored" | tail -5 >&2
  echo "(pg_restore reported problems; full log data/backups/restore-$stamp.log)" >&2
}
rm -f "data/backups/prod-$stamp.dump"

echo "== Removing prod's credentials from the copy (keeping dev's own settings)"
psql -q -d "$LOCAL_DB" -v ON_ERROR_STOP=1 -c "DELETE FROM user_tokens;" -c "DELETE FROM app_settings WHERE $LOCAL_ONLY;"
if [ -s "data/backups/local-settings-$stamp.tsv" ]; then
  psql -q -d "$LOCAL_DB" -v ON_ERROR_STOP=1 -c "\\copy app_settings (key, value, inserted_at, updated_at) FROM 'data/backups/local-settings-$stamp.tsv'"
  echo "kept dev's $(wc -l < "data/backups/local-settings-$stamp.tsv" | tr -d ' ') own settings"
fi
rm -f "data/backups/local-settings-$stamp.tsv"

echo "== Mirroring uploaded files (only what changed travels; files prod no longer has are removed here)"
RSYNC=$(command -v /opt/homebrew/bin/rsync /usr/local/bin/rsync rsync | head -1)
mkdir -p priv/static/uploads
"$RSYNC" -e "${SSH[*]}" -aW --delete "$SSH_HOST:$REMOTE/data/files/uploads/" priv/static/uploads/

echo "== Running migrations newer than prod"
mix ecto.migrate --quiet

cat <<MSG

Done: $LOCAL_DB and priv/static/uploads match prod as of $(date "+%b %-d %H:%M").
- Start the dev server (mix phx.server) and sign in as on prod (password, or the local Authentik once
  RULEMAVEN_OIDC_* are set for dev).
- Prod's keys and secrets aren't copied; dev's own were kept (set more in the admin pages or .envrc.local).
- To go back: dropdb $LOCAL_DB && createdb $LOCAL_DB && pg_restore -d $LOCAL_DB --no-owner data/backups/local-$stamp.dump
MSG
exit
}
