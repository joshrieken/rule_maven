# Project Overview

Rule Maven — a Phoenix LiveView app (installable as a PWA) that answers board
game rules questions at the table. Pick a game, ask a question in plain English,
get an answer grounded in that game's actual rulebook text.

- **Type:** Phoenix web app (LiveView)
- **Domain:** personal / friend-group board game tool
- **Status:** active development

## Tech Stack

- Elixir ~> 1.15, OTP 29
- Phoenix 1.8 + LiveView
- Ecto + PostgreSQL (with pgvector extension for embeddings)
- LLM: multi-provider via OpenAI-compatible API (Req HTTP client) — OpenRouter, Groq, Gemini, Ollama
- Background jobs: Oban
- Version manager: asdf — versions pinned in `.tool-versions`

## Setup

```bash
mix setup          # deps.get + ecto.create + ecto.migrate + seeds
mix deps.get
mix ecto.setup     # create, migrate, seed
```

- **NEVER start the server.** User starts server manually.
  Before any server-related check, verify server is NOT already running.

## Common Commands

- (User starts server manually)
- Run server w/ IEx: `iex -S mix phx.server`
- Compile (strict): `mix compile --warnings-as-errors`
- Run all tests: `mix test`
- Run one file: `mix test test/path/to/file_test.exs`
- Run one test: `mix test test/path/to/file_test.exs:42`
- Re-run failures only: `mix test --failed`
- Format check: `mix format --check-formatted`
- Format fix: `mix format`
- Static analysis: `mix credo --strict`
- Type checking: `mix dialyzer`
- Full pre-commit check: `mix format && mix credo --strict && mix test`

Run full pre-commit check before considering any change finished.
Don't skip `mix compile --warnings-as-errors` — warnings in Elixir are
frequently real bugs (unused variables in pattern matches, unreachable clauses).

## Database

- PostgreSQL with `pgvector` extension for embedding similarity search
- Migrations are additive and reversible by default (`change/0`)
- Never edit a migration that has been merged/run elsewhere — write new one
- Never run `mix ecto.reset` / `mix ecto.drop` except local dev/test
- Ask before running any destructive Ecto task
- Index foreign keys and columns used in WHERE/ORDER BY

## Workers (Oban)

- Workers live under `lib/rule_maven/workers/`, one responsibility per worker
- Jobs must be idempotent — assume at-least-once delivery
- Use `unique` opts to prevent duplicate enqueues
- Don't change queue concurrency or job max_attempts without flagging operational impact

## Production

**Prod data is the source of truth** (user rule, 2026-11-15). New content (imports, prepares, corrections) is processed IN PRODUCTION via `bin/prod <cmd>` (server tools container: deployed code, prod DB, Oban queues off). Dev is a disposable copy: `bin/pull-prod` replaces `rule_maven_dev` + `priv/static/uploads` with prod's (saves the old dev DB to `tmp/` first; truncates `oban_jobs`, restores the local `llm_proxy_url`). Never treat dev data as something to push up.

Live at https://rulemaven.com on the shared server (`ssh deploy@207.244.249.148`, checkout `/opt/rulemaven`), alongside Drawburn / Stir & Fold behind the server's Traefik (Cloudflare in front; port 22 only via the raw IP).

- Stack: `Dockerfile` (Elixir release, poppler + tesseract in runtime) + `compose.yaml` (app + `pgvector/pgvector:pg18` db, Traefik labels). Server `.env`: `RULEMAVEN_HOST`, `SECRET_KEY_BASE`, `POSTGRES_PASSWORD`, plus the sign-on/hub vars (see "Single sign-on" below).
- Data: `/opt/rulemaven/data/{postgres,files,backups}`. `files/` = `UPLOADS_DIR` (holds `uploads/rulebooks`, `uploads/symbols`).
- Deploy is release-only: commit `Release vX.Y.Z` (bump `VERSION` + `CHANGELOG.md` entry; never put the version back in `mix.exs`: any mix.exs change recompiles everything), push master, then `ssh deploy@207.244.249.148 'cd /opt/rulemaven && (nohup ./scripts/deploy.sh > data/deploy-last.log 2>&1 < /dev/null &)'` and poll `data/deploy-last.log` for `Up:` (a foreground ssh can hang after the remote finishes) (pg_dump backup → ff master → build → up → wait for `/health` to report the version → seed new flags).
- Migrations run on container start (`bin/migrate`). Roll back: see header of `scripts/deploy.sh`.
- LLM provider/keys/models live in the DB (`app_settings`), not env. Prod must have `llm_proxy_url` unset (the headroom proxy is local-only).
- Console: `docker compose exec rulemaven bin/rule_maven remote`.
- Build speed: `_build` is a BuildKit cache mount (`id=rulemaven-build`), and `deps/` are BuildKit cache mounts (`rulemaven-build`, `rulemaven-deps`), so a release recompiles only changed files (~15s build; whole deploy is mostly the restart). If a cache ever goes bad: `docker builder prune`.
- PDFs are compressed after upload (`PdfCompressWorker`); recompress everything: `docker compose exec rulemaven bin/rule_maven rpc "RuleMaven.PdfCompress.backfill() |> IO.inspect()"`.

## Single sign-on (shared Authentik)

Rule Maven signs in through the Low-Cal Calzone Zone account (`../identity`, blueprint
`blueprints/rulemaven.yaml`, issuer `https://id.lowcalcalzonezone.com/application/o/rulemaven/`),
like Drawburn and Stir & Fold. Code: `Auth.Oidc` (protocol), `Auth.SignOn` (who), flow in
`data-flows.md` "Sign-in". Rules: when configured it is the ONLY way in (password, registration,
reset, sign-in links, confirmation all refuse); people are linked by `users.oidc_sub` only (never
email/username); group check (`rulemaven-users` or `rulemaven-admins`) and admin re-sync at every
sign-in (super_admin is server-only and never changed); sign-on sessions last 7 days; sign-out
also ends the Authentik session (back to `/login`). Unset `RULEMAVEN_OIDC_ISSUER` = off (dev, tests).

- Server `.env` (`/opt/rulemaven/.env`): `RULEMAVEN_OIDC_ISSUER`, `RULEMAVEN_OIDC_CLIENT_SECRET`
  (same value as `RULEMAVEN_OIDC_CLIENT_SECRET` in `/opt/identity/.env`); optional
  `RULEMAVEN_HUB_SECRET`. `compose.yaml` defaults client id `rulemaven`, groups, and the name
  "Low-Cal Calzone Zone". The app refuses to start with an issuer but no secret, or a non-https issuer.
- Redirect URIs come from `:public_url` (`PUBLIC_URL`, else `https://$PHX_HOST`), not the admin
  "public URL" setting and never request headers.
- Local: `cd ../identity && docker compose up -d` (http://localhost:9000, `RULEMAVEN_URL=http://localhost:4000`
  in its `.env`), then start the dev server with `RULEMAVEN_OIDC_ISSUER=http://localhost:9000/application/o/rulemaven/`,
  `RULEMAVEN_OIDC_CLIENT_ID`, `RULEMAVEN_OIDC_CLIENT_SECRET` (http issuers are allowed outside prod).

**Migrating existing accounts (do this before turning it on):**
1. identity: copy the `RULEMAVEN_*` block from `.env.example` into `/opt/identity/.env` (generate the
   secret), `docker compose -f compose.yaml -f compose.prod.yaml up -d --force-recreate server worker`, then
   `docker compose exec -T worker ak apply_blueprint /blueprints/apps/rulemaven.yaml`.
2. Authentik admin (over the SSH tunnel, see identity README): make sure each Rule Maven person has an
   account; add them to `rulemaven-users` (admins to `rulemaven-admins`).
3. Deploy the release with sign-on still OFF (migration adds `users.oidc_sub`, makes email optional).
4. Link each existing account to its Authentik account: `bin/prod mix rule_maven.link_sso --list`, then
   `bin/prod mix rule_maven.link_sso USERNAME SUB` (SUB = the person's `sub`: Authentik's default
   "hashed user ID", the UID on the user's page in the Authentik admin; the same value as their
   `users.oidc_sub` in Drawburn / Stir & Fold / the hub if they already use those). Link your own
   (super admin) account first.
5. Set `RULEMAVEN_OIDC_ISSUER` + `RULEMAVEN_OIDC_CLIENT_SECRET` in `/opt/rulemaven/.env` and
   `docker compose up -d`. Passwords stop working. Password sessions from before keep working 30
   days from their sign-in, so anyone not linked yet can use Settings → "Link your Low-Cal Calzone
   Zone account".
6. If someone signed in with sign-on before being linked, they got a new empty account: unlink it
   (`… link_sso NEWNAME --unlink`), link their old one (`… link_sso OLDNAME SUB`), and delete the empty one in /admin/users.
- Admin changes: Promote/Demote in /admin/users only lasts until that person's next sign-in; use the
  Authentik groups. Invite codes and "create user" are unused while sign-on is on.

## Safety Rails — Always Ask First

Pause and confirm before:
- Adding, removing, or upgrading a dependency in `mix.exs`
- Any schema or migration change that alters or drops a column/table
- Editing CI/CD config (`.github/workflows/`, etc.)
- Touching anything under `config/` related to secrets, or any `.env` file
- Running a destructive mix task (`ecto.drop`, `ecto.reset`) outside local dev
- Force-pushing, rebasing shared history, or deleting a branch
- Bumping the Elixir/OTP/Phoenix version
