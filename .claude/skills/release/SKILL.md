---
name: release
description: Cut a Rule Maven release - pick the next version from what changed, write the changelog (Everyone / Admins), bump VERSION, and make the tagged "Release vX.Y.Z" commit that scripts/deploy.sh (and the server's autodeploy) deploys. Use when the user says "release", "cut a release", "prepare a release/deployment", "ship it", "bump the version", or "/release".
---

# Release Rule Maven

The Low-Cal Calzone Zone release process (`PLATFORM.md` §4–5, identical in every repo). The server deploys
only a commit whose subject is exactly `Release vX.Y.Z` and whose `VERSION` says `X.Y.Z`; that commit
holds nothing but the version bump and the new `CHANGELOG.md` entry. **Once pushed, autodeploy puts it live
within about a minute** (PLATFORM.md §5.4), so pushing a release is deploying it.

1. **Start clean**: on `master`, `git status` clean, up to date with `origin`. Uncommitted changes: stop
   and ask; never fold them into the release commit.
2. **Last release**: `git log --grep='^Release v[0-9]' -1 --format='%h %s'`.
3. **What changed**: `git log --reverse --format='%h %s%n%b' <last>..HEAD`, then the diff where a message is
   unclear (`git diff --stat <last>..HEAD`). Messages say intent; the diff is the truth.
4. **Version** from the current `VERSION`: minor if people or admins can see or do anything new, patch for
   fixes and internals, major only when the owner says so (while 0.x a breaking change is a minor that says so).
   Highest wins.
5. **Notes**: a new entry at the top of `CHANGELOG.md` (`## vX.Y.Z (YYYY-MM-DD)`, date from `date +%F`):
   - `### Everyone`: what people notice, in their words: what they can now do and where. Most noticeable first.
   - `### Admins`: admin pages, server/deploy/upkeep, anything an operator must do ("Action needed: …" first),
     including any migration that needs care.
   - Leave out internal-only changes unless they change behaviour; omit an empty section; if nothing anyone
     would notice changed, release a patch with one Admins line ("Internal improvements.").
   - Never how to exploit a security fix, never secrets, tokens, people's names or their content.
   Rename `## Unreleased` to the new version and date if it has notes, rather than writing them again.
6. **Bump**: write `X.Y.Z` to `VERSION`.
7. **Check**: `mix test`, `mix format --check-formatted`, `mix compile --warnings-as-errors` (AGENTS.md has the rest). All green, or stop.
8. **Commit** only `VERSION`, `CHANGELOG.md`: subject exactly `Release vX.Y.Z`, the notes as the body, ending with the
   session's `Co-Authored-By` line. Tag: `git tag -a vX.Y.Z -m "Release vX.Y.Z"`.
9. **Push only if the user asked to ship**: `git push --follow-tags origin master`. Otherwise tell them the
   version, why (the deciding change), the notes, and that pushing deploys it. To deploy by hand or roll back:
   `ssh deploy@207.244.249.148 'cd /opt/<app> && ./scripts/deploy.sh [<release commit>]'`.

Never amend or move a pushed release commit; a fix after it is a new release.
