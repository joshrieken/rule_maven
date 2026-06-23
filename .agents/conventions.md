# Code Conventions

## Formatting

`mix format` is the source of truth. Don't hand-format around it; if
the formatter does something undesirable, fix it via `.formatter.exs`.

## Patterns

- **Pipelines:** prefer `|>` chains over deeply nested calls; break on
  multiple lines once it stops fitting on one.
- **Pattern matching over conditionals:** prefer multiple function
  heads / `case` over `if/else` chains when branching on a value's shape.
- **Tagged tuples:** public functions that can fail return `{:ok, result}` /
  `{:error, reason}`. Use `with` for chaining multiple fallible steps;
  don't nest `case` more than two levels deep — extract a private function.
- **Contexts:** business logic lives in context modules (`lib/rule_maven/`),
  not in controllers, LiveViews, or schemas. Schemas hold data shape +
  changesets only.
- **Naming:** modules `PascalCase`, files/functions `snake_case`,
  booleans/predicates end in `?` (not `is_`), unsafe/raising variants end in `!`.
- **No bare `String.to_atom/1`** (or `to_existing_atom`) on user input —
  atom table exhaustion risk.
- **Avoid `Enum` for work that should stream** — use `Stream` for large
  or lazy collections.
- **Structs over bare maps** for internal data passed between modules,
  once it has a stable shape.
- Keep modules small and focused; if a module exceeds ~300 lines or mixes
  more than one responsibility, split it.

## Testing

- Framework: ExUnit. Tests default to `async: true` unless they touch
  shared/global state (e.g. `Application.put_env/3`, DB sandbox in shared mode).
- Factories/fixtures kept in `test/support/`.
- DB: tests use `Ecto.Adapters.SQL.Sandbox`; don't write tests that depend on
  data persisting across test cases.
- Every bug fix gets a regression test. Every new public function gets a test
  covering the happy path and at least one failure path.
- Don't delete or skip (`@tag :skip`) a failing test to make the suite pass.

## TDD Workflow (mandatory)

1. **Write test first** — red. One focused test case.
2. **Run `mix test test/path/to/file_test.exs`** — confirm it fails.
3. **Implement minimal code** — green. No extra abstractions.
4. **Run full suite `mix test`** — confirm no regressions.
5. **Run `mix compile --warnings-as-errors`** — zero warnings.
6. **Commit** — atomic, descriptive message.

Never skip step 2 or 4. Regressions are unacceptable.

## LLM Mocking

For tests that call `RuleMaven.LLM.ask/4` or `RuleMaven.LLM.chat/3`, inject mock via:

```elixir
Application.put_env(:rule_maven, :llm_mock, fn body ->
  {:ok, %{answer: "test", cited_passage: "test", followup: false, followups: []}}
end)
on_exit(fn -> Application.delete_env(:rule_maven, :llm_mock) end)
```

Mock intercepts at `do_request/3` (before HTTP call). Returns
`do_request_real` output format: `{:ok, %{answer:, cited_passage:, followup:, followups:}}`.
Body passed to mock has atom keys:
`%{messages: [%{role: "system", content: _}, %{role: "user", content: _}]}`.

## Git Workflow

- **Branch naming:** `type/short-description` — e.g.
  `feat/oban-job-retries`, `fix/changeset-validation`, `chore/bump-deps`.
- **Commits:** small and atomic — one logical change per commit.
  Imperative mood: `Add retry backoff`, not `Added` or `Adding`.
  Conventional Commits prefix: `feat:`, `fix:`, `chore:`, `refactor:`, `test:`, `docs:`.
  Body explains *why*, not just *what*, when change isn't self-evident.
- **Never commit or push without being explicitly asked.**
- **Never force-push, rebase, or rewrite history on shared/remote branch.**
- **Never `git reset --hard` or discard uncommitted changes** without confirming.
- Keep `main` always deployable; land work behind feature flag if incomplete.
- PR description: what changed, why, how tested, follow-up work left out.

## LiveView — Stale UI After DB Update

**Problem:** `handle_event` updates DB, assigns same value to socket,
UI doesn't update until manual refresh.

**Root cause:** LiveView skips re-render when assign value hasn't changed
(`assign(socket, foo: true)` when `foo` was already `true`).

**Fix pattern:** Add a `refresh` counter to socket assigns. Increment on
every action that changes DB state. The changing counter value forces
LiveView to re-render the entire template.

```elixir
# In mount:
assign(socket, refresh: 0)

# In every handler that modifies DB state:
refresh = socket.assigns.refresh + 1
{:noreply, assign(socket, refresh: refresh, ...)}
```

**Do NOT use `push_patch` or `push_navigate` to self** — that restarts
the LiveView, loses state, and adds latency. Counter pattern is zero-cost.

**CRITICAL: Put refresh attribute on an always-present element** — never
inside a conditional block (`if`, `for`, `else`). If conditional removes
the element from DOM, refresh reference is lost and LiveView stops
re-rendering that section. Always put `data-refresh={@counter}` on the
outermost wrapper div that always exists (even if hidden with `display:none`).

## Dev Server

- **Never start your own dev server.** If one isn't running and you need it, ask the user.
- **Server logs are in `tmp/`**, not `log/`. Check `tmp/` for runtime output, crash dumps, or Erlang error logs.
- The user's dev server runs in their terminal; yours would port-conflict and cause confusion.

## Running Tests

- **HARD RULE: Never run the full test suite (`mix test`) unless:** (a) you are about to commit, or (b) changes span >3 files and targeted tests aren't practical. In all other cases, run only relevant tests.
- Default: `mix test test/path/to/file_test.exs` or `mix test test/path/file_test.exs:LINE`.
- If changes span multiple files (e.g. renaming a function), use a glob: `mix test test/rule_maven_web/live/game_live/*_test.exs`.
- Run full suite at session end, and always before committing.
