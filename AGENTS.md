# AGENTS.md

> Authoritative entry point for AI coding agents working in this repository.
> Progressive disclosure: this file is the index. Load detail docs only when needed.

## Project

Rules Buddy — Phoenix LiveView PWA for board game rules Q&A.
Ask questions in plain English, get answers grounded in rulebook text.

## Quick Index

| Topic | File |
|-------|------|
| Project overview, tech stack, setup, safety rails | [`.agents/overview.md`](.agents/overview.md) |
| Codebase map (every module, file, function) | [`.agents/codebase-map.md`](.agents/codebase-map.md) |
| Data flows (ask question, save rulebook, FAQ cluster) | [`.agents/data-flows.md`](.agents/data-flows.md) |
| Conventions (formatting, testing, git, LiveView patterns) | [`.agents/conventions.md`](.agents/conventions.md) |

## How to Use

1. Read this file first.
2. Scan the codebase map to find target files for your task.
3. Load only those files. Do NOT scan the entire tree.
4. Use the data flows doc to understand how things connect.

## Continual Self-Improvement (meta)

Your own context is your scarcest resource. Actively protect it:

- **Load minimal context.** Use the codebase map to identify the 1-3 files you need. Never scan the whole tree. Never read a file you don't need.
- **If a task forced you to explore broadly**, add a "Quick Reference" row to `.agents/codebase-map.md` so future you doesn't repeat the search.
- **If docs grow stale**, update them immediately. Stale docs are worse than no docs — they misdirect.
- **If a doc is too verbose**, compress it. Remove filler, keep substance. The `.agents/` files are for agents, not humans.
- **After every task**, ask: could I have done this with less context? If yes, improve the map so next time you can.

## Self-Maintenance (mandatory)

After every code change, update the relevant doc. At minimum:

- **New module/file added** → add row to `.agents/codebase-map.md`
- **Module removed or renamed** → update all references in `.agents/codebase-map.md` and `.agents/data-flows.md`
- **Public function added/changed** → update Key Functions column in `.agents/codebase-map.md`
- **Line count changed significantly** → update Lines column
- **New data flow or changed flow** → update `.agents/data-flows.md`
- **New convention or changed workflow** → update `.agents/conventions.md`

**Process:** After `mix test` passes and before commit, check:
1. Did I create, rename, or delete any module? → update map
2. Did I change any public function signature? → update map
3. Did I change a data flow? → update flows doc
4. Did the line count change by >50 lines? → update map

If answer is yes to any, update the doc *in the same commit*.

## Common Commands

- Compile (strict): `mix compile --warnings-as-errors`
- Run all tests: `mix test`
- Run one test: `mix test test/path/to/file_test.exs:42`
- Format fix: `mix format`
- Static analysis: `mix credo --strict`
- Full pre-commit check: `mix format && mix credo --strict && mix test`

**Skip tests** when only `.md`, `.agents/`, or doc files changed. No code path affected.

## Commit Discipline

- Conventional Commits: `feat:`, `fix:`, `chore:`, `refactor:`, `test:`, `docs:`
- Atomic commits, imperative mood
- Never commit/push without being explicitly asked
- Run full pre-commit check before every commit
- **Commit after completing work.** Do not leave uncommitted changes at session end.
