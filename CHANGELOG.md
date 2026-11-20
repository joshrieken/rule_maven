# Changelog

What changed in each release of Rule Maven, newest first. The app shows this at /changelog
("What's new", opened from the version beside the name in the header): everyone sees
"Everyone"; admins also see "Admins".

Each production deploy is a `Release vX.Y.Z` commit that bumps `VERSION` and adds an entry here
(`scripts/deploy.sh` refuses anything else). Format, which the app parses at compile time:

    ## vX.Y.Z (YYYY-MM-DD)
    ### Everyone
    - One bullet per change, in plain words for the people using the app.
      A long bullet can continue on indented lines.
    ### Admins
    - Admin tools, operations and upkeep changes.

Notes for the next release go under `## Unreleased` (the app ignores it); the release commit
renames that heading to the new version and date.

## Unreleased
### Admins
- Removed: the old invite codes' table (unused since v0.6.5). Group invite links are unchanged.

## v0.6.6 (2026-11-19)
### Everyone
- Fixed: re-asking or regenerating a follow-up question now remembers the conversation before it, so the new answer builds on the earlier questions like the first one did.

### Admins
- Improved: internal code cleanup with no change in behaviour (every `mix credo --strict` finding fixed).

## v0.6.5 (2026-11-19)
### Admins
- Removed: the old sign-up invite codes (the Invite Codes admin page and the invite-code registration
  page). Access comes from the Low-Cal Calzone Zone sign-in: people ask from the hub and an admin
  approves. Old /register links now open the sign-in page. Group invite links are unchanged.
- Fixed: deleting a user who once made an invite code no longer fails (the code just forgets who made it; the
  old table goes in a later release).

## v0.6.4 (2026-11-19)
### Admins
- Import tasks and import-prepare scripts refuse to write to the dev database; production is the source of truth. Put `bin/prod` in front of the command (or `RULEMAVEN_DEV_WRITE=1` for a deliberate dev experiment).
- `bin/prod` refuses to run while the local import code differs from what is deployed (`PROD_STALE_OK=1` overrides).
- The dev copy of the app shows a "Dev copy" banner so local changes aren't mistaken for production ones.
- Deploys now run exactly the verified release commit.

## v0.6.3 (2026-11-18)
### Everyone
- Stronger browser security: pages now only run Rule Maven's own scripts.
### Admins
- Rulebook text copies are safer to open: rulebook text is shown exactly as written, and the
  page runs in its own sandbox (the light/dark choice there is no longer remembered).

## v0.6.2 (2026-11-18)

### Everyone

- Code blocks in answers show as plain text (no colour highlighting) after a library update; everything else looks the same.

### Admins

- Library updates: sign-in, background jobs (Oban and its dashboard), Markdown rendering, vector search, browser-test tooling; a fix for leftover background processes in the app's container.

## v0.6.1 (2026-11-18)

### Everyone

- Game pages and Prepare open noticeably faster.
- Moving between pages no longer replays the panels' entrance animations, so nothing flickers.

### Admins

- Usage and Moderation show their numbers straight away when they're quick to read; the job panel, DB Admin, Security and Themes read less.

## v0.6.0 (2026-11-17)

### Everyone

- Moving between pages is quicker: the header, the menu and Prepare's links open pages without reloading, and a thin bar at the top shows when one is on its way.

### Admins

- The admin pages move live too; Usage and Moderation load their numbers after the page shows.
- DB Admin opens the users table again (JSON columns crashed it).

## v0.5.6 (2026-11-17)

### Admins

- Security updates for several libraries the app uses (including the web framework, the database driver and the email sender). Nothing changes for anyone.
- Email still goes through Resend, now through the mail library's own built-in support for it.

## v0.5.5 (2026-11-17)

### Admins

- Internal improvements: sign-in, sign-out everywhere, the hub summary and the changelog now come from the shared Low-Cal Calzone Zone library. Nothing changes for anyone.

## v0.5.4 (2026-11-17)
### Everyone
- Log in at the top (and in the menu on phones) signs you in straight away, without a second button to find.

## v0.5.3 (2026-11-17)
### Everyone
- After signing out anywhere, the header no longer shows your name on the sign-in page.

## v0.5.2 (2026-11-17)
### Everyone
- Signing out anywhere also closes Rule Maven pages you already have open (they go to the sign-in page).

## v0.5.1 (2026-11-17)
### Admins
- Sign out everywhere reaches Rule Maven too (the sign-in service's notice was being redirected).

## v0.5.0 (2026-11-17)
### Everyone
- Signing out signs you out of every Low-Cal Calzone Zone app at once, and signing out of any of them signs you out here too.

## v0.4.0 (2026-11-17)
### Admins
- Who's a super admin now comes from the Low-Cal Calzone Zone sign-in (the rulemaven-superadmins group), checked at every sign-in, like admin already is. The question-writing service account isn't affected.

## v0.3.1 (2026-11-17)
### Admins
- The hub summary endpoint without `?sub` answers just `{ version }`, so the hub can show every app's version.

## v0.3.0 (2026-11-16)
### Everyone
- Already signed in to your Low-Cal Calzone Zone account? Rule Maven signs you in by itself.

## v0.2.5 (2026-11-16)
### Everyone
- Rule Maven now signs you in with your Low-Cal Calzone Zone account, the same one you use for
  Drawburn, Stir & Fold and the hub at lowcalcalzonezone.com. Signing out of Rule Maven also signs
  you out of that account.

## v0.2.4 (2026-11-16)
### Admins
- Deploys drop no requests: Traefik retries a request that reaches the retiring version on the new one.

## v0.2.3 (2026-11-15)
### Admins
- Deploys no longer take the site down: the new version starts alongside the old one and takes
  over once it's ready. A release that fails to start is removed and the old one keeps serving.
  Database migrations must now work with the previous release too (add now, remove later).

## v0.2.2 (2026-11-15)
### Admins
- Shorter blip during deploys: the new version is put back into service within a second or two
  of starting, and the deploy script only reports "Up" once visitors can reach it.

## v0.2.1 (2026-11-15)
### Everyone
- The version number and What's new now appear only once you're signed in.
### Admins
- The version shown always matches the release (a version-only release used to keep showing the
  previous number). `/health` reports the version only from inside the server.

## v0.2.0 (2026-11-15)
### Admins
- Single sign-on is built in, off until configured. Before turning it on, link every existing account to its Low-Cal Calzone Zone
  account (`bin/prod mix rule_maven.link_sso USERNAME SUB`) and add people to `rulemaven-users`
  (admins to `rulemaven-admins`) in the account admin; then set `RULEMAVEN_OIDC_ISSUER` and
  `RULEMAVEN_OIDC_CLIENT_SECRET` on the server. From then on passwords, registration and invite
  codes are off, admin rights follow the `rulemaven-admins` group at each sign-in, and sign-ins
  last a week. Steps: `.agents/overview.md` "Single sign-on".
- The Low-Cal Calzone Zone hub can show Rule Maven (questions this week, last game) once
  `RULEMAVEN_HUB_SECRET` is set here and in the hub.

## v0.1.7 (2026-11-15)
### Admins
- Updated the web server library (Bandit 1.14.1) for a security fix in its HTTP/2 handling.

## v0.1.6 (2026-11-15)
### Everyone
- The version number now sits beside the Rule Maven name at the top of every page. Tap it to see
  what's new in each release; a small red dot on it means there are notes you haven't read yet.

## v0.1.5 (2026-11-15)
### Admins
- Operations: faster deploys.

## v0.1.4 (2026-11-15)
### Admins
- Operations: quieter maintenance commands.

## v0.1.3 (2026-11-15)
### Admins
- Operations: new games and fixes are now processed directly on the live site.

## v0.1.2 (2026-11-15)
### Admins
- Uploaded rulebook PDFs are compressed to the resolution answers are read at (much smaller files, same pages).
- Rate limits now see each visitor's real address.

## v0.1.1 (2026-11-15)
### Admins
- Sign-in and password-reset rate limits now count each visitor separately behind the proxy.

## v0.1.0 (2026-11-15)
### Everyone
- First production deploy at rulemaven.com.
