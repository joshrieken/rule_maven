# Progressive Disclosure Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `.agents/` docs from drifting further and make sure every AI-tool entrypoint (Claude Code, opencode, Copilot) can find them.

**Architecture:** Doc-only edits to `AGENTS.md`, `.opencode/AGENTS.md`, `.github/copilot-instructions.md`, plus one new shell script wired into `.claude/settings.json` as a `PreToolUse` hook on `git commit`.

**Tech Stack:** Markdown docs, bash, Claude Code hooks (`.claude/settings.json`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-05-progressive-disclosure-design.md`.
- Hook must be advisory (exit 0, stderr warning) — never block a commit.
- `.clinerules/caveman.md` is out of scope — leave untouched.
- Skip tests when only `.md`/`.agents/`/doc files change (per `AGENTS.md`), but this plan does modify `.claude/settings.json` and add a script, so those two get manually exercised (Task 3).

---

### Task 1: Strip dead caveman block from `AGENTS.md`

**Files:**
- Modify: `AGENTS.md:75-89` (delete the caveman block; everything from `Respond terse like smart caveman.` through `Boundaries: code/commits/PRs written normal.`)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks — this is a straight deletion.

- [ ] **Step 1: Delete lines 75-89 of `AGENTS.md`**

Current tail of file (lines 73-89):

```markdown
- Run full pre-commit check before every commit

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
```

Replace with just:

```markdown
- Run full pre-commit check before every commit
```

(i.e. delete everything after the "Commit Discipline" section's last bullet — file now ends there.)

- [ ] **Step 2: Verify**

Run: `tail -5 AGENTS.md`
Expected output ends with `- Run full pre-commit check before every commit` and nothing about caveman.

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "docs: drop dead caveman block from AGENTS.md (Claude Code gets it via global hook already)"
```

---

### Task 2: Give `.opencode/AGENTS.md` and `.github/copilot-instructions.md` the progressive-disclosure index

**Files:**
- Modify: `.opencode/AGENTS.md` (currently 15 lines, caveman-only)
- Modify: `.github/copilot-instructions.md` (currently 15 lines, caveman-only, identical content to above)

**Interfaces:**
- Consumes: the Quick Index table and How to Use list already present in root `AGENTS.md` (copy verbatim, do not re-derive).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Prepend index block to `.opencode/AGENTS.md`**

New full file content:

```markdown
# AGENTS.md (opencode)

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
```

- [ ] **Step 2: Prepend same index block to `.github/copilot-instructions.md`**

New full file content:

```markdown
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
```

- [ ] **Step 3: Verify links resolve**

Run: `ls .agents/overview.md .agents/codebase-map.md .agents/data-flows.md .agents/conventions.md`
Expected: all four files listed, no "No such file" errors. (Relative path `../.agents/...` from `.opencode/` and `.github/` both resolve to repo-root `.agents/`.)

- [ ] **Step 4: Commit**

```bash
git add .opencode/AGENTS.md .github/copilot-instructions.md
git commit -m "docs: add progressive-disclosure index to opencode/copilot entrypoints"
```

---

### Task 3: Advisory staleness-check hook

**Files:**
- Create: `.claude/hooks/check-agents-docs.sh`
- Modify: `.claude/settings.json` (add `hooks.PreToolUse` entry)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing consumed later — terminal task.

- [ ] **Step 1: Create the hook script**

```bash
#!/usr/bin/env bash
# Advisory nag: warn (don't block) if a commit touches lib/*.ex without touching .agents/*.md.
set -euo pipefail

staged="$(git diff --cached --name-only 2>/dev/null || true)"

if [ -z "$staged" ]; then
  exit 0
fi

touches_lib=false
touches_agents=false

while IFS= read -r path; do
  case "$path" in
    lib/*.ex) touches_lib=true ;;
    .agents/*.md) touches_agents=true ;;
  esac
done <<< "$staged"

if [ "$touches_lib" = true ] && [ "$touches_agents" = false ]; then
  echo "[check-agents-docs] Staged lib/*.ex changes with no .agents/*.md update." >&2
  echo "[check-agents-docs] New/renamed module, changed public function, or changed data flow? Update .agents/codebase-map.md or .agents/data-flows.md. Otherwise ignore." >&2
fi

exit 0
```

- [ ] **Step 2: Make it executable and verify it runs standalone**

```bash
chmod +x .claude/hooks/check-agents-docs.sh
git add lib/rule_maven/games.ex 2>/dev/null || true  # any tracked lib file, no-op if none staged
.claude/hooks/check-agents-docs.sh
git reset lib/rule_maven/games.ex 2>/dev/null || true
```

Expected: if a `lib/*.ex` path was staged, script prints the two `[check-agents-docs]` lines to stderr and exits 0. If nothing was staged, script exits 0 silently.

- [ ] **Step 3: Wire into `.claude/settings.json`**

Current file:

```json
{
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true
  }
}
```

New file:

```json
{
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "case \"$CLAUDE_TOOL_INPUT_COMMAND\" in *git\\ commit*) bash .claude/hooks/check-agents-docs.sh ;; esac"
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 4: Verify end-to-end**

```bash
echo "# test comment" >> lib/rule_maven/faq.ex
git add lib/rule_maven/faq.ex
git commit -m "test: trigger staleness hook (will be reverted)"
```

Expected: commit succeeds, and `[check-agents-docs]` warning appears in the tool output before/around the commit. Then revert the test change:

```bash
git revert --no-edit HEAD
```

- [ ] **Step 5: Commit the hook itself**

```bash
git add .claude/hooks/check-agents-docs.sh .claude/settings.json
git commit -m "chore: add advisory hook nagging on lib/ changes without .agents/ doc updates"
```

---

## Self-Review Notes

- Spec coverage: Task 1 = spec change 1, Task 2 = spec change 2, Task 3 = spec change 3. All three spec changes covered.
- No placeholders: every step has literal file content or literal command.
- Type/interface consistency: N/A (no code interfaces between tasks — each task is independent doc/config work).
