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
