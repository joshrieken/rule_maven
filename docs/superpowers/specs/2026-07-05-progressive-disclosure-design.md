# Progressive Disclosure Hardening — Design

## Problem

`.agents/` + `AGENTS.md` already implement progressive disclosure (index → detail
docs, load-on-demand). At 147 lib files it's drifting:

- `.agents/codebase-map.md` last touched 2026-06-24. Since then: 526 commits
  touching `lib/`, only 2 touching `.agents/`. The mandatory
  "update docs in same commit" rule in `AGENTS.md` exists but isn't enforced —
  prose alone doesn't hold at this commit volume.
- Caveman-mode instructions duplicated across 4 files (`AGENTS.md`,
  `.opencode/AGENTS.md`, `.github/copilot-instructions.md`,
  `.clinerules/caveman.md`). `AGENTS.md`'s copy is dead weight for Claude Code
  (already injected via global hook) but the other three are load-bearing for
  their respective tools (opencode, Copilot, Cline don't get that hook).
- `.opencode/AGENTS.md` and `.github/copilot-instructions.md` currently contain
  *only* the caveman block — no pointer to `.agents/*.md`. Any agent entering
  through those tools gets zero progressive-disclosure benefit; only root
  `AGENTS.md` readers (Codex-style) see the index.

## Goals

1. Every tool entrypoint (root `AGENTS.md`, `.opencode/AGENTS.md`,
   `.github/copilot-instructions.md`) points into the same `.agents/` detail
   docs — no tool is left scouring the tree cold.
2. Remove genuinely dead duplication without breaking tools that need their
   own copy.
3. Make doc-staleness visible automatically instead of relying on an agent
   remembering a prose rule mid-task.

## Changes

### 1. Strip dead caveman copy from `AGENTS.md`

Claude Code gets caveman mode via the global `~/.claude` hook already —
`AGENTS.md`'s copy never fires for Claude Code and only adds noise for other
readers of that file. Remove it; `AGENTS.md` becomes pure index +
project/commands/safety content (as it mostly already is).

### 2. Give other tool entrypoints the same index pointer

`.opencode/AGENTS.md` and `.github/copilot-instructions.md` keep their
caveman block (still load-bearing for those tools) but each gains the same
"Quick Index" + "How to Use" block already in root `AGENTS.md`, pointing at
`.agents/overview.md`, `.agents/codebase-map.md`, `.agents/data-flows.md`,
`.agents/conventions.md`. `.clinerules/caveman.md` is caveman-only by
convention (Cline loads it for style, not project context) — leave it as is.

### 3. Staleness check via Claude Code hook

Add a `PreToolUse` hook (matcher: `Bash` commands matching `git commit`) that
runs a small script:

- `git diff --cached --name-only` — if any `lib/**/*.ex` path is staged and no
  `.agents/*.md` path is staged in the same commit, print a warning to stderr
  (non-blocking, exit 0) reminding the agent to check whether
  `codebase-map.md`/`data-flows.md` need updating, or note why not.
- Kept advisory, not blocking: some commits (pure bugfix, no new
  module/function-signature change) legitimately don't need a doc touch, and
  the existing `AGENTS.md` self-maintenance checklist already tells the agent
  how to decide. A hard block would just train agents to `--no-verify` around
  it.

Script lives at `.claude/hooks/check-agents-docs.sh` (or equivalent), wired
via project `.claude/settings.json`.

## Non-goals

- No auto-generation of `codebase-map.md` from source — the hand-curated
  "Key Functions"/"Quick Reference" columns are the valuable part; a codegen
  pass would need to merge with curated content, more machinery than the
  problem currently warrants.
- No further splitting of `codebase-map.md` by domain — file is ~120 lines,
  not yet unwieldy. Revisit if it crosses ~300 lines.

## Testing

- Manual: stage a `lib/` change without touching `.agents/`, run `git commit`,
  confirm hook prints warning and commit still succeeds.
- Manual: stage a `lib/` change together with a `.agents/` doc change, confirm
  no warning.
- Read-through: confirm `.opencode/AGENTS.md` and `copilot-instructions.md`
  render sensibly with both caveman + index content (no duplication of the
  index itself, since only one copy per file).
