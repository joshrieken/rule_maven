# Changelog

Each production deploy is a `Release vX.Y.Z` commit that bumps `version` in `mix.exs` and adds an entry here (`scripts/deploy.sh` refuses anything else).

## v0.1.1 — 2026-11-15

- Sign-in and password-reset rate limits now count each visitor separately behind the proxy.

## v0.1.0 — 2026-11-15

- First production deploy at rulemaven.com.
