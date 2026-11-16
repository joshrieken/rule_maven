# Changelog

Each production deploy is a `Release vX.Y.Z` commit that bumps `VERSION` and adds an entry here (`scripts/deploy.sh` refuses anything else).

## v0.1.4 — 2026-11-15

- Operations: quieter maintenance commands.

## v0.1.3 — 2026-11-15

- Operations: new games and fixes are now processed directly on the live site.

## v0.1.2 — 2026-11-15

- Uploaded rulebook PDFs are compressed to the resolution answers are read at (much smaller files, same pages).
- Rate limits now see each visitor's real address.

## v0.1.1 — 2026-11-15

- Sign-in and password-reset rate limits now count each visitor separately behind the proxy.

## v0.1.0 — 2026-11-15

- First production deploy at rulemaven.com.
