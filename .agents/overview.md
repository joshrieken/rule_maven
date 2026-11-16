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

Live at https://rulemaven.com on the shared server (`ssh deploy@207.244.249.148`, checkout `/opt/rulemaven`), alongside Drawburn / Stir & Fold behind the server's Traefik (Cloudflare in front; port 22 only via the raw IP).

- Stack: `Dockerfile` (Elixir release, poppler + tesseract in runtime) + `compose.yaml` (app + `pgvector/pgvector:pg18` db, Traefik labels). Server `.env`: `RULEMAVEN_HOST`, `SECRET_KEY_BASE`, `POSTGRES_PASSWORD`.
- Data: `/opt/rulemaven/data/{postgres,files,backups}`. `files/` = `UPLOADS_DIR` (holds `uploads/rulebooks`, `uploads/symbols`).
- Deploy is release-only: commit `Release vX.Y.Z` (bump `mix.exs` version + `CHANGELOG.md` entry), push master, then `ssh deploy@207.244.249.148 'cd /opt/rulemaven && ./scripts/deploy.sh'` (pg_dump backup → ff master → build → up → wait for `/health` to report the version → seed new flags).
- Migrations run on container start (`bin/migrate`). Roll back: see header of `scripts/deploy.sh`.
- LLM provider/keys/models live in the DB (`app_settings`), not env. Prod must have `llm_proxy_url` unset (the headroom proxy is local-only).
- Console: `docker compose exec rulemaven bin/rule_maven remote`.
- Build speed: `_build` is a BuildKit cache mount (`id=rulemaven-build`), so a code-only deploy recompiles just the changed files (~15s build); apt/deps layers are cached. If the cache ever goes bad: `docker builder prune --filter id=rulemaven-build` (or `docker builder prune`).
- PDFs are compressed after upload (`PdfCompressWorker`); recompress everything: `docker compose exec rulemaven bin/rule_maven rpc "RuleMaven.PdfCompress.backfill() |> IO.inspect()"`.

## Safety Rails — Always Ask First

Pause and confirm before:
- Adding, removing, or upgrading a dependency in `mix.exs`
- Any schema or migration change that alters or drops a column/table
- Editing CI/CD config (`.github/workflows/`, etc.)
- Touching anything under `config/` related to secrets, or any `.env` file
- Running a destructive mix task (`ecto.drop`, `ecto.reset`) outside local dev
- Force-pushing, rebasing shared history, or deleting a branch
- Bumping the Elixir/OTP/Phoenix version
