# Low-Cal Calzone Zone platform

How every Low-Cal Calzone Zone app is built, released, deployed and run. One standard for all of them:
the hub (lowcalcalzonezone.com), Drawburn, Stir & Fold, Rule Maven, and the shared sign-in (identity).

**This file is identical in every repo.** The canonical copy lives in the hub repo
(`joshrieken/lowcalcalzonezone`, `PLATFORM.md`). Change it there, then copy it to the others in the same
sitting (`ops/sync-platform.sh` in the hub repo does it). A repo's own `CLAUDE.md`/`AGENTS.md` adds
app-specific rules on top; where they disagree, fix one of them.

## 1. The pieces

| App | Repo | Server checkout | Compose service | Port | Stack |
|---|---|---|---|---|---|
| Hub | `lowcalcalzonezone` | `/opt/hub` | `hub` | 3000 | Node (no framework) |
| Drawburn | `drawburn` (folder `workcard`) | `/opt/drawburn` | `drawburn` | 3000 | Next.js + SQLite |
| Stir & Fold | `gourmand` | `/opt/gourmand` | `stirandfold` | 4637 | Next.js + SQLite |
| Rule Maven | `rule_maven` | `/opt/rulemaven` | `rulemaven` (+ `db`) | 4000 | Phoenix + Postgres |
| Identity | `lccz-identity` | `/opt/identity` | `server`, `worker` (+ `postgresql`) | 9000 | Authentik |
| Rollcall (not ours: kalinkakr's) | `kalinkakr/RollCall` | `/opt/rollcall` | `web` (+ `db`) | 8000 | Django + Postgres |

- **One server** (`deploy@207.244.249.148`), Docker Compose per app, **Traefik** in front (`/opt/traefik`,
  external network `web`, entrypoint `websecure`, Let's Encrypt resolver `le`). DNS goes through Cloudflare's
  proxy, so SSH goes to the IP, never a domain.
- **Each app is a git checkout** in `/opt/<app>`, pulled with its own read-only GitHub deploy key
  (`~/.ssh/<app>_deploy`, host alias `github-<app>` in `~/.ssh/config`). Never build from copied files.
- **Secrets live only in `/opt/<app>/.env`** (chmod 600, never committed). Generate on the server
  (`openssl rand -hex 32`) and write them straight into the files; never print them, paste them into chat,
  or pass them on a command line that's logged. Each repo's `.env.example` lists every variable.
- **Apps reach each other by compose service name** on `web` (`http://drawburn:3000/...`), never by container
  name: rolling deploys renumber containers (`drawburn-drawburn-1` → `-2`).
- **Nothing publishes host ports in production.** Traefik is the only way in (`ports: !reset []`). The
  exceptions are admin-only binds to `127.0.0.1` (Authentik's admin, reached over an SSH tunnel).

## 2. Sign-in (identity)

- **Every app signs in through Authentik** at `id.lowcalcalzonezone.com` (OpenID Connect, code flow + PKCE +
  state + nonce). When configured it's the only way in: no app passwords, registration, resets or invites.
- **One blueprint per app** in `identity/blueprints/<app>.yaml` (copy `drawburn.yaml`): provider, application,
  groups `<app>-users` and `<app>-admins`, a rule that only those groups may open the app, strict redirect URI
  `<APP_URL>/auth/oidc/callback`, logout redirect `<APP_URL>/login`.
- **In the app:** link people by `users.oidc_sub` (unique). Never auto-link by email or username. Re-check the
  group claim at every sign-in; admin = `<app>-admins`, re-synced each time. Sign-on sessions last 7 days.
  Two levels when an app needs them: plain admins run content and moderation; **super admins** (also in
  `<app>-superadmins`, env `<APP>_OIDC_SUPERADMIN_GROUP`; unset = every admin is super) also own settings, AI and
  spending, backups, invites and accounts. Super implies admin; never demote the last super admin.
  Signing out also ends the Authentik session (end-session with `id_token_hint`). Return addresses come from
  configuration (`<APP>_PUBLIC_URL`), never request headers.
- **`sub` is the same person in every app** (subject mode `hashed_user_id` = Authentik user `uid`). The hub and
  cross-app features rely on it; never change a provider's subject mode.
- **One shared admin account:** the Authentik user `admin`, in every `<app>-admins` group. A new app adds it.
  It's a shared login, so it's never a super admin; the owner (`jrieken`) is.
- **Changing a secret in `/opt/identity/.env` isn't enough:** Authentik copies it into its database only when
  the blueprint is applied. Restart, then `docker compose exec -T worker ak apply_blueprint /blueprints/apps/<app>.yaml`.
  Add new env values **before** pulling a new blueprint, or it applies with empty values.

## 3. The hub contract

Every app the hub shows answers, server to server:

```
GET /api/hub/summary?sub=<sign-on id>
Authorization: Bearer <APP>_HUB_SECRET          (unset = always 401)
200 { level: 0-3, active, headline (≤80), detail? (≤120), version, updated }   Cache-Control: no-store
400 missing/oversized sub · 401 wrong secret · 404 nobody with that sub (or suspended)
```

- `level` grows with use (thresholds exported as a constant, e.g. `[1, 10, 50]`), `active` = used in the last
  7 days, `version` = the running version, `updated` = this person has release notes they haven't opened.
- Read-only, the person's own data only, constant-time secret compare (hash both, then `timingSafeEqual`).
- The hub holds the same secret as `HUB_<APP>_SUMMARY_SECRET` and the URL as `HUB_<APP>_SUMMARY_URL`
  (`http://<service>:<port>/api/hub/summary`). It treats every answer as untrusted text.
- Request access: pending = membership of `<app>-requests`; app admins approve in the hub (hub `README.md`).

## 4. Versions, changelog, What's new

- **Semantic versions.** The version lives in `package.json` (Node) or `VERSION` (Elixir). Minor = anything new
  people or admins can see or do; patch = fixes and internals; major only when the owner says so (while 0.x, a
  breaking change is a minor that says so).
- **`CHANGELOG.md`, newest first:**
  ```
  ## vX.Y.Z (YYYY-MM-DD)
  ### Everyone
  - What people notice, in their words: what they can do now and where. Most noticeable first.
  ### Admins
  - Admin pages, server/deploy/upkeep, anything an operator must do ("Action needed: …" first).
  ```
  (Stir & Fold's older entries omit the `v`; every parser accepts both.) Notes waiting for the next release go
  under `## Unreleased`. Never describe how to exploit a security fix; never include secrets or people's data.
- **Every app shows its version** (small `vX.Y.Z` beside the name, or on Help where there's no header), linking
  to **What's new** (`/changelog`): Everyone notes for all, Admins notes for admins only. A **red dot** marks
  release notes this person hasn't opened (`users.seen_version`, set when they open the page; new accounts start
  seen). The dot is `aria-hidden` with screen-reader text.

## 5. Releasing and deploying

**Fast and boring, so it happens often.** A release is a commit; a deploy is one command (or none: §5.4).

### 5.1 Release

1. Clean tree on the default branch, tests green.
2. Pick the version (§4) from what changed since the last `Release v` commit.
3. Write the `CHANGELOG.md` entry and bump the version.
4. Run the full checks (each repo's `CLAUDE.md`/`AGENTS.md` lists them).
5. Commit **only** the version bump + changelog, subject exactly `Release vX.Y.Z`. Tag it:
   `git tag -a vX.Y.Z -m "Release vX.Y.Z"`. Push with `git push --follow-tags`.

Every repo has a `release` skill (`.claude/skills/release/SKILL.md`) that does these steps. Something landing
after a pushed release needs a new release: never amend or move a pushed release commit.

### 5.2 Deploy (`./scripts/deploy.sh` in `/opt/<app>`)

Every app's script does the same steps:

1. **Only release commits deploy**: `Release vX.Y.Z` whose version file says `X.Y.Z`. `./scripts/deploy.sh <commit>`
   deploys an older release (rolling back).
2. **Back up the database first** (SQLite online backup / `pg_dump`), keep the newest 14, owner-only.
3. **Build on the server** with BuildKit cache mounts. Dependency layers only rebuild when the dependencies change:
   Node images install from a `manifest` stage that copies `package.json`/`package-lock.json` with `version` set to
   0.0.0, so a release's version bump doesn't reinstall everything (it cost Stir & Fold ~4 minutes per deploy).
4. **Rolling swap:** start the new container *beside* the running one (`up -d --no-deps --no-recreate --scale`),
   wait until Docker says **healthy** *and* it reports the version just built, wait 2 s for Traefik, then retire
   the old one by id (never a compose scale-down: that may remove the new one). A release that fails to start is
   removed and the old one keeps serving. Traefik's **retry middleware** on every router re-sends a request that
   reaches the retiring container while it shuts down.
5. Prune this project's old images.

**Requirements this puts on the code:**
- **Health checks answer fast**: Docker `HEALTHCHECK --interval=30s --start-interval=1s --start-period=60s` on a
  cheap endpoint, and a version endpoint (`/api/version`, `/health`) the script can read.
- **Migrations work with the previous release too (expand, then contract).** For a few seconds the old release
  runs on the migrated database. Add a column/table in one release, stop using the old one, drop it in a later
  release. Never rename or drop something the previous release still reads.
- **Anything that must happen once claims atomically first** (emails, pushes, scheduled jobs): two copies run
  during the swap. Write the "done" mark with a conditional update and act only if this process won it
  (Stir & Fold's `claimDaily`; Oban jobs are already unique).
- **Shut down gracefully on SIGTERM**: stop accepting, drop idle keep-alive connections, finish in-flight work.
- **Changing Traefik labels** (routers, middlewares) makes the old and new containers disagree during the swap;
  Traefik may drop the router for those seconds. Expect one blip on that deploy only.

### 5.3 Timings to keep

A cached deploy (code change, same lockfile) should take **under ~15 s** end to end, and the swap itself ~3 s,
with no failed requests. If a step gets slower, fix it rather than living with it: the faster a deploy is, the
more often it happens.

### 5.4 Continuous deployment

`ops/autodeploy.sh` (hub repo) runs on the server every minute (cron) and deploys any app whose default branch
has a new `Release v` commit that isn't running yet. So: **push a release, it's live in about a minute.** Pull-based:
GitHub holds no key to the server. Logs: `~/lccz-autodeploy/<app>.log` (on the server). To deploy by hand
anyway, run the app's `scripts/deploy.sh`; to pause one app, `touch /opt/<app>/.no-autodeploy`.

## 6. Development

- **Pinned toolchains** in `.tool-versions` (asdf). Node apps: after switching Node, `npm rebuild better-sqlite3`.
- **Framework docs from the installed version**, not memory (Next.js: `node_modules/next/dist/docs/`).
- **Data layer owns rules**: every data function takes the user first and checks permission itself; pages, routes
  and actions stay thin. Capped lists (`MAX_*`). Untrusted input validated at the edge (zod / changesets).
- **Tests next to the code**, against a real temporary database. Every repo's full check suite must pass before a
  release (tests, types, lint, build or the Elixir equivalents).
- **Security baseline**: strict CSP where feasible, POST + origin check for state changes, secrets compared in
  constant time, no server-side fetch of user URLs without the SSRF guard, errors shown via flash (never raw in
  URLs), user text always escaped.
- **Look**: always dark (`#0e0e10`), warm off-white text, red accent `#e5484d`, Atkinson Hyperlegible, rem units,
  17px base, mobile first, accessible (labels, focus rings, `prefers-reduced-motion`).
- **Keep users' docs true**: a user-visible change updates the app's Help/guide and its changelog in the same change.
- **Agents (Claude Code)**: read this file, then the repo's `CLAUDE.md`/`AGENTS.md`. Never push or deploy unless
  the owner asks (a pushed release *is* a deploy once autodeploy is on). Commit messages end with the
  `Co-Authored-By` line the session gives.

## 7. Adding an app

1. Repo with this file, `.env.example`, `compose.yaml` + production overlay with Traefik labels (router, service,
   retry middleware), `Dockerfile` (multi-stage, non-root, `HEALTHCHECK` as §5.2), `scripts/deploy.sh` (copy
   Drawburn's), a `release` skill, `CHANGELOG.md`, version display + What's new.
2. Identity: blueprint `<app>.yaml`, env block in `/opt/identity/.env` (before pulling), apply it, add `admin`
   to `<app>-admins`.
3. Server: deploy key + `github-<app>` alias, `git clone` into `/opt/<app>`, `.env`, first `./scripts/deploy.sh`.
4. Hub: entry in `src/apps.js` (+ illustration), summary endpoint + `HUB_<APP>_SUMMARY_*`, `<app>-requests`
   group in `identity/blueprints/hub-access.yaml`.
5. Add it to the table in §1, to `ops/autodeploy.sh`, and to `ops/pull-prod-all.sh` with its own
   `scripts/pull-prod.sh` (§8).

## 8. Production data on dev

**One command, from your Mac, with the dev servers stopped:** `hub/ops/pull-prod-all.sh` (or name apps:
`hub/ops/pull-prod-all.sh drawburn`). It runs `identity/scripts/pull-prod.sh` first, then each app's
`scripts/pull-prod.sh`. Each script can run alone (identity first, the first time).

- **Why identity goes first:** apps link people by Authentik's `sub`, which depends on the installation. Copying
  prod's Authentik database (it carries the installation id) makes local `sub`s equal prod's, so the apps' copied
  accounts sign in locally. The script then re-applies every local app blueprint whose `<APP>_OIDC_CLIENT_SECRET`
  is in the local `identity/.env`, so redirects point at localhost again (others keep prod's settings and won't
  sign in locally), and re-applies branding. Prod passwords work locally.
- **Never copied (or removed from the copy):** sign-in sessions, API/CLI tokens, and credential settings (email,
  LLM, BGG keys, proxies, the app's public address). Nothing local can send email, spend, or act as prod. An app
  that stores dev's own credentials in its database keeps them across the pull (Rule Maven's `app_settings`).
- **Prod is read-only:** SQLite online backup in the running container / `pg_dump`. Files **mirror** prod by rsync
  (only changes travel; files prod no longer has are removed locally; regenerable caches like `images/sized` stay). **The local copy is kept first** (`data/backups/local-*`, or `identity/backups/`), and each
  script prints how to go back. Prod dumps are deleted once restored.
- **Each script refuses** if its dev server is running (port in use) or the database is open: swapping a database
  under a running server corrupts it.
- **Code ahead of prod:** migrations newer than prod run on the next dev start (Rule Maven's script runs them).
- **What lands where:** identity → local Authentik's Postgres (docker compose); Drawburn → `data/drawburn.db`;
  Stir & Fold → `data/stirandfold.db` + `data/images`, `data/inbox` (~2.4 GB the first time); Rule Maven →
  `rule_maven_dev` on the local Postgres + `priv/static/uploads`. The hub keeps no data.
- **SSH:** every script uses `deploy@207.244.249.148` (override with `LCCZ_SSH`; Stir & Fold also reads
  `STIRANDFOLD_SSH` from `.env.prod`). Never a domain: Cloudflare's proxy doesn't carry SSH.

## 9. Dev environment (the zone in Docker)

**The whole zone runs on your Mac shaped like production; any one app can run natively for speed.**
Everything lives in the hub repo's `dev/`:

```sh
hub/dev/setup.sh      # once (re-run after adding an app): local secrets (hub/dev/.env), local Authentik's app addresses
hub/dev/up.sh         # start: local Authentik + Traefik + every app (or name some: hub/dev/up.sh drawburn hub)
hub/dev/down.sh       # stop the containers (--all stops the local Authentik too); deps, builds and data stay
hub/dev/native.sh <app>   # run that app natively instead (fastest reloads), same address, same settings
hub/ops/pull-prod-all.sh  # production data into dev (§8); the containers use the same files and databases
```

| Address | What |
|---|---|
| http://lccz.localhost | hub |
| http://drawburn.lccz.localhost | Drawburn |
| http://stirandfold.lccz.localhost | Stir & Fold |
| http://rulemaven.lccz.localhost | Rule Maven |
| http://id.lccz.localhost | sign-in (local Authentik; admin interface also at http://localhost:9000) |
| http://traefik.lccz.localhost | routing dashboard |

- **Like production:** each app is built from production's base image with its system tools (`dev/images/`:
  poppler, Ghostscript, Tesseract, the same Node/Elixir/OTP), runs from your repo (bind-mounted, hot reload), and
  reaches the others **by service name** on the `lccz-dev` network. Sign-in, hub summaries and "Updated" work as on
  the server. `*.lccz.localhost` resolves to Traefik inside the network too (network aliases), so the browser and
  the servers agree on the sign-in address.
- **Native fallback:** Traefik routes an app's address to its container (priority 100) or, when that's stopped, to
  the Mac's port (`dev/traefik/dynamic.yaml`: 3300 hub, 3000 Drawburn, 4637 Stir & Fold, 4000 Rule Maven).
  `native.sh` stops the container and starts the dev server natively with the stack's settings; `up.sh <app>`
  puts the container back.
- **Data:** each repo's own `./data` (bind-mounted, so native and container see the same files); Rule Maven uses the
  Mac's Postgres (`rule_maven_dev`, Postgres 18 like production) via `PGHOST=host.docker.internal`.
- **Dependencies** live in volumes (Linux builds of native modules); they reinstall only when the lockfile changes.
  First start: a few minutes (installs, Rule Maven compiles); later starts: about a minute.
- **Tests and tools still run natively by default** (fast). For exact parity, run them in the container:
  `docker compose -f hub/dev/compose.yaml exec <app> npm test` (or `mix test`).
- **A Next.js app reloads itself in a loop** (its console says `HMR hash mismatch`): its build cache in the
  container went stale (code changed a lot underneath it). Clear it and restart:
  `docker compose -f hub/dev/compose.yaml rm -sf <app> && docker volume rm lccz-dev_<app>-next && hub/dev/up.sh <app>`,
  then hard-refresh the browser (Cmd+Shift+R).
- **`curl` inside a container can't test `*.localhost` names** (it always uses loopback for them); the apps
  (Node, Erlang) resolve them normally.
- **Secrets:** `hub/dev/.env` (chmod 600, git-ignored) holds dev-only secrets, shared with the local
  `identity/.env`. Never production's.
- **New app:** add its service to `dev/compose.yaml` (image, bind mount, env like production's, Traefik labels with
  priority 100), a native fallback route, its block in `setup.sh` and `native.sh`, and a network alias.

## 10. Backups and disaster recovery

**Everything that isn't in git is backed up off-site every night, and a fresh machine becomes the whole zone
in three commands.** Scripts in the hub repo's `ops/`; one restic repository (Backblaze B2), encrypted with
`RESTIC_PASSWORD`. **Keep that password and the bucket's keys in your password manager, off the server**:
without them the backups can't be read.

| Tag | What | Made by |
|---|---|---|
| `stirandfold` | database, photos, cookbooks, `secret.key` | Stir & Fold's `scripts/offsite-backup.sh` (03:15; its admin page reports on it) |
| `drawburn` | database (SQLite online backup) | `ops/backup.sh` (03:45) |
| `rulemaven` | `pg_dump` + uploaded files | `ops/backup.sh` |
| `identity` | Authentik `pg_dump` + its media and certs | `ops/backup.sh` |
| `rollcall` | `pg_dump` + uploaded media | `ops/backup.sh` |
| `secrets` | every `/opt/*/.env*`, `/opt/traefik` (config + certificates), `~/.ssh` (deploy keys), the crontab | `ops/backup.sh` |
| `pre-optimize` | Stir & Fold's originals before the 2026-11-16 file optimization (kept for good) | by hand |

Kept: 7 daily, 5 weekly, 12 monthly per tag. `ops/backup.sh` checks 2% of the stored data every Sunday and, when
`BACKUP_PING_URL` is set in `/opt/hub/.env.backup`, pings it after a fully successful night (an Uptime Robot
heartbeat alerts on a missed ping). Log: `~/lccz-backups/backup.log`.

**Restore one thing** (same server or new): `ops/restore.sh <secrets|identity|drawburn|stirandfold|rulemaven|rollcall|all> [snapshot]`
(`ops/restore.sh snapshots` lists them). It stops the app, keeps a copy of what it replaces, restores, starts it.
Secrets never overwrite existing files unless `FORCE=1`.

**Rebuild the server** (`ops/bootstrap.sh`, details at its top):
1. New Debian/Ubuntu machine with your SSH key for root; `scp ops/bootstrap.sh root@NEW:/root/`; `./bootstrap.sh system`.
2. As `deploy`: the restic settings into `~/.env.backup` (chmod 600), then `./bootstrap.sh keys` (restores the deploy
   keys GitHub already knows).
3. `./bootstrap.sh apps`: clones, restores secrets and every app's data, starts Traefik, Authentik (+ blueprints),
   every app at its latest release, Rollcall, and the cron jobs.
4. Point every domain's A record in Cloudflare at the new IP. Check every site and Uptime Robot.

**Tested so far:** end to end against a local restic repository and a stand-in `/opt` (backup, wipe, restore of every
tag, Stir & Fold's own snapshots included), and the real database commands against copies of production data. Not
yet on a real fresh server: the first rebuild is that test.

