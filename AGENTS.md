# AGENTS.md

> Instructions for AI coding agents (opencode and compatible tools)
> working in this repository.
> Replace bracketed placeholders with real project details.
> Commit this file to git.

## Project Overview

Rules Buddy — a Phoenix LiveView app (installable as a PWA) that answers board
game rules questions at the table. Pick a game, ask a question in plain English,
get an answer grounded in that game's actual rulebook text.

- **Type:** Phoenix web app (LiveView)
- **Domain:** personal / friend-group board game tool
- **Status:** greenfield

## Tech Stack

- Elixir ~> 1.15, OTP 29
- Phoenix 1.8 + LiveView
- Ecto + PostgreSQL
- LLM: Anthropic Claude API (via Req HTTP client)
- Version manager: asdf — versions pinned in `.tool-versions`

## Setup

```bash
mix setup          # deps.get + ecto.create + ecto.migrate + seeds
mix deps.get
mix ecto.setup     # create, migrate, seed
```

- **NEVER start the server.** The user starts the server themselves.
  Before running any server-related check, first verify the server
  is NOT already running (do NOT start it).

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
- Full pre-commit check:
  `mix format && mix credo --strict && mix test`

Run the full pre-commit check before considering any change
finished. Don't skip `mix compile --warnings-as-errors` —
warnings in Elixir are frequently real bugs (unused variables
in pattern matches, unreachable clauses).

## Code Conventions

- **Formatting:** `mix format` is the source of truth. Don't
  hand-format around it; if the formatter does something
  undesirable, fix it via `.formatter.exs`, not by fighting it
  inline.
- **Pipelines:** prefer `|>` chains over deeply nested calls;
  break a pipeline onto multiple lines once it stops fitting
  on one.
- **Pattern matching over conditionals:** prefer multiple
  function heads / `case` over `if/else` chains when branching
  on a value's shape.
- **Tagged tuples:** public functions that can fail return
  `{:ok, result}` / `{:error, reason}`. Use `with` for chaining
  multiple fallible steps; don't nest `case` more than two
  levels deep — extract a private function instead.
- **Contexts:** business logic lives in context modules
  (`lib/my_app/accounts.ex` etc.), not in controllers,
  LiveViews, or schemas. Schemas hold data shape + changesets
  only.
- **Naming:** modules `PascalCase`, files/functions
  `snake_case`, booleans/predicates end in `?` (not `is_`),
  unsafe/raising variants end in `!`.
- **No bare `String.to_atom/1`** (or `to_existing_atom`) on
  user input — atom table exhaustion risk.
- **Avoid `Enum` for work that should stream** — use `Stream`
  for large or lazy collections.
- **Structs over bare maps** for any internal data passed
  between modules, once it has a stable shape.
- Keep modules small and focused; if a module exceeds ~300
  lines or mixes more than one responsibility, that's a signal
  to split it.

## Testing

- Framework: ExUnit. Tests default to `async: true` unless
  they touch shared/global state (e.g.
  `Application.put_env/3`, the DB sandbox in shared mode).
- Mocking: [Mox] for behaviours; don't reach for mocks unless
  a real boundary (external API, time, etc.) requires one.
- Factories/fixtures: [ExMachina / context-defined fixtures] —
  keep them in `test/support/`.
- DB: tests use `Ecto.Adapters.SQL.Sandbox`; don't write tests
  that depend on data persisting across test cases.
- Every bug fix gets a regression test. Every new public
  function gets a test covering the happy path and at least
  one failure path.
- Don't delete or skip (`@tag :skip`) a failing test to make
  the suite pass — fix the code or the test, or flag it
  explicitly and ask.

## Database & Migrations

- Migrations are additive and reversible by default
  (`change/0`, not one-way `up/0` + `down/0` unless genuinely
  irreversible — and say so in a comment if so).
- Never edit a migration that has already been merged/run
  elsewhere — write a new one.
- Never run `mix ecto.reset` / `mix ecto.drop` against
  anything but a local dev/test database. Ask before running
  any destructive Ecto task.
- Index foreign keys and any column used in a `WHERE` or
  `ORDER BY` on a non-trivial table.

## Background Jobs (if using Oban)

- Workers live under `lib/my_app/workers/`, one job
  responsibility per worker.
- Jobs must be idempotent — assume at-least-once delivery.
- Use `unique` opts to prevent duplicate enqueues where
  retries could double-schedule work.
- Don't change a queue's concurrency or a job's `max_attempts`
  without flagging the operational impact (this affects DB
  connection pressure under PgBouncer-style poolers).

## Git Workflow

- **Branch naming:** `type/short-description` — e.g.
  `feat/oban-job-retries`, `fix/changeset-validation`,
  `chore/bump-deps`.
- **Commits:** small and atomic — one logical change per
  commit. Write commit messages in imperative mood: `Add
  retry backoff to import worker`, not `Added` or `Adding`.
  - Conventional Commits prefix where useful: `feat:`,
    `fix:`, `chore:`, `refactor:`, `test:`, `docs:`.
  - Body explains *why*, not just *what*, when the change
    isn't self-evident from the diff.
- **Never commit or push without being explicitly asked to.**
  Staging and committing on the user's behalf without a clear
  go-ahead is not assumed default behavior — propose the
  commit message and wait for confirmation unless told
  otherwise up front.
- **Never force-push, rebase, or rewrite history on a
  shared/remote branch** (`main`, `master`, `develop`, or any
  branch others may have pulled). Force-push is only
  acceptable on a private feature branch the agent created in
  this session, and only if asked.
- **Never `git reset --hard` or discard uncommitted local
  changes** without confirming first — there may be work that
  isn't backed up anywhere else.
- Keep `main`/`master` always deployable; land work behind a
  feature flag if it's incomplete but needs to merge.
- Before opening a PR: rebase on the latest target branch
  locally if the workflow prefers linear history, otherwise
  merge — match whatever the existing repo history already
  does rather than introducing a new pattern.
- PR description should state: what changed, why, how it was
  tested, and any follow-up work intentionally left out.

## Safety Rails — Always Ask First

The agent should pause and confirm before:

- Adding, removing, or upgrading a dependency in `mix.exs`
- Any schema or migration change that alters or drops a
  column/table
- Editing CI/CD config (`.github/workflows/`, etc.)
- Touching anything under `config/` related to secrets, or
  any `.env` file
- Running a destructive mix task (`ecto.drop`, `ecto.reset`)
  outside local dev
- Force-pushing, rebasing shared history, or deleting a branch
- Bumping the Elixir/OTP/Phoenix version

## When Uncertain

If a requirement is ambiguous, or a change could be
implemented two reasonable ways with different tradeoffs
(performance vs. readability, strict vs. lenient validation,
sync vs. async), say so and ask rather than silently picking
one. Surface the tradeoff in a sentence or two — don't just
guess and move on.

## LiveView — Stale UI After DB Update

**Problem:** `handle_event` updates DB, assigns same value to socket, UI doesn't update until manual refresh.

**Root cause:** LiveView skips re-render when assign value hasn't changed (`assign(socket, foo: true)` when `foo` was already `true`).

**Fix pattern:** Add a `refresh` counter to socket assigns. Increment on every action that changes DB state. The changing counter value forces LiveView to re-render the entire template.

```elixir
# In mount:
assign(socket, refresh: 0)

# In every handler that modifies DB state:
refresh = socket.assigns.refresh + 1
{:noreply, assign(socket, refresh: refresh, ...)}
```

**Do NOT use `push_patch` or `push_navigate` to self — that restarts the LiveView, loses state, and adds latency. The counter pattern is zero-cost.

**CRITICAL: Put the refresh attribute on an always-present element** — never inside a conditional block (`if`, `for`, `else`). If the conditional removes the element from the DOM, the refresh reference is lost and LiveView stops re-rendering that section. Always put `data-refresh={@counter}` on the outermost wrapper div that always exists (even if hidden with `display:none`).
