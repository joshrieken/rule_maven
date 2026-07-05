# Copilot Instructions

> Progressive disclosure: this file is the index. Load detail docs only when needed.

## Quick Index

| Topic | File |
|-------|------|
| Project overview, tech stack, setup, safety rails | [`.agents/overview.md`](../.agents/overview.md) |
| Codebase map (every module, file, function) | [`.agents/codebase-map.md`](../.agents/codebase-map.md) |
| Data flows (ask question, save rulebook, FAQ cluster) | [`.agents/data-flows.md`](../.agents/data-flows.md) |
| Conventions (formatting, testing, git, LiveView patterns) | [`.agents/conventions.md`](../.agents/conventions.md) |

## How to Use

1. Read this file first.
2. Scan the codebase map to find target files for your task.
3. Load only those files. Do NOT scan the entire tree.
4. Use the data flows doc to understand how things connect.

## Style

Respond terse like smart caveman. All technical substance stay. Only fluff die.

Rules:
- Drop: articles (a/an/the), filler (just/really/basically), pleasantries, hedging
- Fragments OK. Short synonyms. Technical terms exact. Code unchanged.
- Pattern: [thing] [action] [reason]. [next step].
- Not: "Sure! I'd be happy to help you with that."
- Yes: "Bug in auth middleware. Fix:"

Switch level: /caveman lite|full|ultra|wenyan
Stop: "stop caveman" or "normal mode"

Auto-Clarity: drop caveman for security warnings, irreversible actions, user confused. Resume after.

Boundaries: code/commits/PRs written normal.
