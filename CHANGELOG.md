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
