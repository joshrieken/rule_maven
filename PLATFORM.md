# Low-Cal Calzone Zone platform

How every Low-Cal Calzone Zone app is built, released, deployed and run. One standard for all of them:
the hub (lowcalcalzonezone.com), Drawburn, Stir & Fold, Rule Maven, and the shared sign-in (identity).

**This file is identical in every repo.** The canonical copy lives in the hub repo
(`joshrieken/lowcalcalzonezone`, `PLATFORM.md`). Change it there, then copy it to the others in the same
sitting (`ops/sync-platform.sh` in the hub repo does it). A repo's own `CLAUDE.md`/`AGENTS.md` adds
app-specific rules on top; where they disagree, fix one of them.

**Running it** (what's on the server, what runs on its own, backups, the maintenance plan, costs, what to do when
something breaks): `OPERATIONS.md` in the hub repo.

## 1. The pieces

| App | Repo | Server checkout | Compose service | Port | Stack |
|---|---|---|---|---|---|
| Hub | `lowcalcalzonezone` | `/opt/hub` | `hub` (+ `db`) | 3000 | Phoenix + Postgres |
| Drawburn | `drawburn` (folder `workcard`) | `/opt/drawburn` | `drawburn` (+ `db`) | 3000 | Phoenix + Postgres |
| Stir & Fold | `gourmand` | `/opt/gourmand` | `stirandfold` (+ `db`) | 4637 | Phoenix + Postgres |
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
- **How people get in:** an app admin's invite link from the hub (Invites: pick which of their apps; one use, 7
  days; `identity/blueprints/invites.yaml`), a hub access request an app admin approves, or an Authentik admin
  adding them to `<app>-users`. Accounts made from an invite have an unchecked email (path `users/invited`): an
  app's email mapping claims `email_verified` only for the default path `users`.
- **One blueprint per app** in `identity/blueprints/<app>.yaml` (copy `drawburn.yaml`): provider, application,
  groups `<app>-users` and `<app>-admins`, a rule that only those groups may open the app, strict redirect URI
  `<APP_URL>/auth/oidc/callback`, logout redirect `<APP_URL>/login`.
- **In the app:** link people by `users.oidc_sub` (unique). Never auto-link by email or username. Re-check the
  group claim at every sign-in; admin = `<app>-admins`, re-synced each time. Sign-on sessions last 7 days.
  Two levels when an app needs them: plain admins run content and moderation; **super admins** (also in
  `<app>-superadmins`, env `<APP>_OIDC_SUPERADMIN_GROUP`; unset = every admin is super) also own settings, AI and
  spending, backups and accounts. Super implies admin; never demote the last super admin.
  Signing out also ends the Authentik session (end-session with `id_token_hint`). **Sign out everywhere:** when an
  Authentik session ends (signed out in any app, expired after its 7 days, or ended by an admin under Directory → Users →
  Sessions), Authentik's worker POSTs a signed logout token to each app's `POST /auth/oidc/backchannel` over the internal
  network (blueprint `logout_uri`, `logout_method: backchannel`, `access_token_validity: days=7`; `blueprints/sessions.yaml`
  makes Authentik sessions 7 days). The app checks it like an ID token (provider's keys, issuer, audience, expiry) plus the
  logout event and no nonce, then ends every browser session of that `sub` (CLI tokens may stay) and makes pages
  already open follow without a reload by hand (Rule Maven: LiveView `live_socket_id` disconnect; Stir & Fold: the bell's
  live stream; Drawburn: a server-sent `ended` on a small session stream; the hub: LiveView `live_socket_id` disconnect,
  its sessions in Postgres like the apps'). Return addresses come from
  configuration (`<APP>_PUBLIC_URL`), never request headers.
- **`sub` is the same person in every app** (subject mode `hashed_user_id` = Authentik user `uid`). The hub and
  cross-app features rely on it; never change a provider's subject mode.
- **One shared admin account:** the Authentik user `admin`, in every `<app>-admins` group. A new app adds it.
  It's a shared login, so it's never a super admin; the owner (`jrieken`) is.
- **Changing a secret in `/opt/identity/.env` isn't enough:** Authentik copies it into its database only when
  the blueprint is applied. Restart, then `docker compose exec -T worker ak apply_blueprint /blueprints/apps/<app>.yaml`.
  Add new env values **before** pulling a new blueprint, or it applies with empty values.

**Elixir apps share one copy of all of the above:** `hub/platform/elixir/lccz` (tested there with `mix test`) is
copied into every Phoenix app's `lib/lccz` by `ops/sync-platform.sh` — never edit an app's copy. It holds the sign-in
protocol and logout tokens (`use Lccz.Oidc`), group levels (`Lccz.Groups`), silent sign-in (`use Lccz.SilentSignIn`),
sign out everywhere (`Lccz.Backchannel`, `Lccz.LiveSessions`), the hub contract (`Lccz.Hub`) and What's new (`Lccz.Changelog`).

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
- **Webring**: every app shows the Calzone Zone Ring (`Lccz.Webring.links("<slug>")`: previous, next, random
  and the hub) at the very foot of its pages, small and faint (a ◀ 🥟 ▶ that brightens and names its links on
  hover or focus): an easter egg, not navigation. The hub shows it openly in its footer. A new app adds itself to
  the ring in `platform/elixir/lccz/lib/lccz/webring.ex` (then sync) and to its own footer.

## 4. Versions, changelog, What's new

- **Semantic versions.** The version lives in `VERSION`. Minor = anything new
  people or admins can see or do; patch = fixes and internals; major only when the owner says so (while 0.x, a
  breaking change is a minor that says so).
- **`CHANGELOG.md`, newest first:**
  ```
  ## vX.Y.Z (YYYY-MM-DD)
  ### Everyone
  - New: What people notice, in their words: what they can do now and where.
  - Improved: …
  - Fixed: …
  ### Admins
  - Action needed: … (first, when there is one)
  - New: Admin pages, server/deploy/upkeep.
  - Security: …
  ```
  (Stir & Fold's older entries omit the `v`; every parser accepts both.) Notes waiting for the next release go
  under `## Unreleased`. Never describe how to exploit a security fix; never include secrets or people's data.
- **Every changelog bullet starts with its kind**, and within each section bullets go in this order (most
  noticeable first within a kind):
  - `New:` something people (or admins) can do or see that they couldn't before.
  - `Improved:` something that already existed works better, faster or more clearly.
  - `Fixed:` something that was wrong now works as it should.
  - `Security:` a security fix or hardening (never how to exploit it).
  - `Removed:` something taken away or replaced.
  Admins' `Action needed:` lines come before everything else in their section. A release with nothing anyone
  would notice still says so: `- Improved: Internal improvements.` under Admins.
- **Commit subjects say their kind** (Conventional Commits): `type: what changed`, or `type(area): …`.
  `feat` (→ New), `fix` (→ Fixed), `fix(security)` (→ Security), `perf` and user-visible polish `feat`/`fix` as
  fits (→ Improved), `refactor`, `docs`, `test`, `build` (dependencies, Docker, tooling), `ci`, `chore` (anything
  else). A removal is `feat!:` or `refactor!:` with the reason in the body (→ Removed when people notice). A commit
  doing two kinds of thing is two commits. **Release commits are the exception**: subject exactly
  `Release vX.Y.Z` (deploys match it, §5).
- **Every app shows its version** (small `vX.Y.Z` beside the name, or on Help where there's no header), linking
  to **What's new** (`/changelog`): Everyone notes for all, Admins notes for admins only. A **red dot** marks
  release notes this person hasn't opened (`users.seen_version`, set when they open the page; new accounts start
  seen). The dot is `aria-hidden` with screen-reader text.

## 5. Releasing and deploying

**Fast and boring, so it happens often.** A release is a commit; a deploy is one command (or none: §5.4).

### 5.1 Release

1. Clean tree on the default branch, tests green.
2. Pick the version (§4) from what changed since the last `Release v` commit.
3. Write the `CHANGELOG.md` entry (every bullet with its kind, §4; the commit types since the last release say
   which) and bump the version.
4. Run the full checks (each repo's `CLAUDE.md`/`AGENTS.md` lists them).
5. Commit **only** the version bump + changelog, subject exactly `Release vX.Y.Z`. Tag it:
   `git tag -a vX.Y.Z -m "Release vX.Y.Z"`. Push with `git push --follow-tags`.

Every repo has a `release` skill (`.claude/skills/release/SKILL.md`) that does these steps. Something landing
after a pushed release needs a new release: never amend or move a pushed release commit.

### 5.2 Deploy (`./scripts/deploy.sh` in `/opt/<app>`)

Every app's script does the same steps:

1. **Only release commits deploy**: `Release vX.Y.Z` whose version file says `X.Y.Z`. `./scripts/deploy.sh <commit>`
   deploys an older release (rolling back).
2. **Back up the database first** (`pg_dump`), keep the newest 14, owner-only.
3. **Build on the server** with BuildKit cache mounts: `deps/` and `_build/` (and hex/npm downloads) live in caches
   that survive between builds, so a deploy fetches and compiles only what changed, a version bump included.
4. **Rolling swap:** start the new container *beside* the running one (`up -d --no-deps --no-recreate --scale`),
   wait until Docker says **healthy** *and* it reports the version just built, wait 2 s for Traefik, then retire
   the old one by id (never a compose scale-down: that may remove the new one). A release that fails to start is
   removed and the old one keeps serving. Traefik's **retry middleware** on every router re-sends a request that
   reaches the retiring container while it shuts down.
5. Prune this project's old images.

The build cache is pruned server-wide, not per deploy: `ops/prune-build-cache.sh` (hub repo, cron every hour)
keeps the 40 GB most recently used and never touches the cache mounts, so builds stay as fast as before.

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

Every autodeploy is timed: its log stamps each line with the seconds since the start, and
`~/lccz-autodeploy/timings.csv` gets one row per deploy (total and each `== step`). `ops/deploy-times.sh` reports
per app (median, last, slowest step); `ops/deploy-times.sh <app>` shows the last deploys step by step.
Targets for a cached deploy (code change, same lockfiles): **hub ~15 s, the Phoenix apps under ~60 s** (build
~30 s, then the swap waits for healthy), with no failed requests. After each release, look at its time; when an
app is over target or got slower, find the step and fix it rather than living with it: the faster a deploy is,
the more often it happens. Known levers: BuildKit cache mounts kept (never prune `exec.cachemount`), npm/apt layers
that only rebuild when their inputs change, `mix compile` without `mix deps.compile` (that one rebuilds rebar
deps such as idna every time, ~17 s on the server), a quick start and health check (the swap waits for healthy).

### 5.4 Continuous deployment

`ops/autodeploy.sh` (hub repo) runs on the server every minute (cron) and deploys any app whose default branch
has a new `Release v` commit that isn't running yet. So: **push a release, it's live in about a minute.** Pull-based:
GitHub holds no key to the server. Logs: `~/lccz-autodeploy/<app>.log` (on the server). To deploy by hand
anyway, run the app's `scripts/deploy.sh`; to pause one app, `touch /opt/<app>/.no-autodeploy`.

**Releases must be signed.** Autodeploy only deploys a release commit signed (git's SSH signing) by a key listed
in `ops/release-signers` (hub repo); anything else is refused, logged, marked like a failed deploy and reported
by the health check. Pushing to GitHub alone (a stolen token, a bad merge) can't put code on the server. Every
repo signs its commits with the owner's release key (repo-local `git config`: `gpg.format ssh`,
`user.signingkey ~/.ssh/lccz_release_signing.pub`, `commit.gpgsign true`), so the `release` skill's commit is
signed with nothing extra to do. Check a release before pushing: `git verify-commit HEAD` (with
`-c gpg.ssh.allowedSignersFile=<hub>/ops/release-signers`). A new key (new laptop, rotation) is a line in
`ops/release-signers`, released in the hub **signed by a key already listed**; remove the old line the same way.
Manual `scripts/deploy.sh` (rollback) isn't checked: whoever runs it is already on the server.

## 6. Development

- **Pinned toolchains** in `.tool-versions` (asdf).
- **Framework docs from the installed version**, not memory (the locked deps' own source and docs in `deps/`).
- **Data layer owns rules**: every data function takes the user first and checks permission itself; pages, routes
  and actions stay thin. Capped lists (`MAX_*`). Untrusted input validated at the edge (zod / changesets).
- **Tests next to the code**, against a real temporary database. Every repo's full check suite must pass before a
  release (tests, types, lint, build or the Elixir equivalents).
- **Security baseline**: strict CSP (`script-src 'self'`: no inline scripts or `on*=` handlers; a per-request
  nonce only for pages a library renders, like the Oban dashboard), POST + origin check for state changes, secrets
  compared in constant time, no server-side fetch of user URLs without the SSRF guard, errors shown via flash (never
  raw in URLs), user text always escaped, including text from files and the web (PDFs, imports) written into HTML.
- **Containers**: the app runs as a non-root user with `cap_drop: [ALL]` and `no-new-privileges`, read-only where
  it can be; every service (app and database) has a `mem_limit` in the production compose file, so a runaway is
  killed and restarted there instead of starving the server (the health check reports any kill).
- **Pages move live, without reloads** (Phoenix): signed-in pages are LiveViews in as few `live_session`s as
  their sign-in needs (normally one for signed-in pages, one for public ones; a page that can't fit, e.g. a
  controller-rendered one, says why). A `live_session` boundary forces a full page load, so never split one by
  feature or permission: admin and super-admin checks are each LiveView's own `on_mount` (and its data functions
  check again). In-app links are `<.link navigate={…}>` (or `patch` within a page), never a bare `<a href>`, so a
  page change swaps the content over the open connection: no reload, no flash, the header stays. Pieces that
  belong to every page (the header, a notice bell) live in the layout; a live one is a sticky
  `live_render(..., sticky: true)`. Plain `<a href>` only for downloads, files, other apps and sign-in/out.
  A page's first (static) render shows its frame and a loading state, not half the data drawn twice. Nothing
  slow runs in a connected mount (the join runs in the socket process and holds its heartbeat: a slow one makes
  the browser fall back to long-polling): load it with `start_async`/`assign_async`. **No flicker**: a page
  reached by a live change shows its final content without visible in-between states (keep recent data to
  paint at once and refresh quietly; a placeholder takes the final layout's exact space), and entry animations
  don't replay on content that was already there.
- **Look**: always dark (`#0e0e10`), warm off-white text, red accent `#e5484d`, Atkinson Hyperlegible, rem units,
  17px base, mobile first, accessible (labels, focus rings, `prefers-reduced-motion`).
- **Keep users' docs true**: a user-visible change updates the app's Help/guide and its changelog in the same change.
- **Keep the zone's docs true**: they're how the owner and future sessions know how things work, so they change in
  the same commit as what they describe: infrastructure, cron, backups, monitoring, costs → `OPERATIONS.md` (hub);
  how every app is built or run → this file (then `ops/sync-platform.sh`, commit the copies); what new apps need →
  `templates/phoenix-app` + `ops/new-app.sh` too; a server-side change → `ops/bootstrap.sh` so a rebuild matches.
- **Agents (Claude Code)**: read this file, then the repo's `CLAUDE.md`/`AGENTS.md`. Never push or deploy unless
  the owner asks (a pushed release *is* a deploy once autodeploy is on). Commit messages end with the
  `Co-Authored-By` line the session gives.

## 7. Adding an app

**Start from the template, never by copying an app:** `hub/templates/phoenix-app` is a complete Phoenix 1.8 +
LiveView + Postgres app that already does everything above (sign-in and sign out everywhere through `lib/lccz`,
groups → user/admin/super admin, sessions in Postgres, one `live_session` with admin checks per LiveView, the hub
summary, What's new, health/version, activity log and server errors, strict CSP, the Dockerfile, compose files,
`scripts/deploy.sh` and `pull-prod.sh`, CI, Dependabot, the `release` skill, tests). In the hub repo:

```sh
ops/new-app.sh <slug> <Module> "<Product name>" <domain> <port>            # shows every zone edit as a diff
ops/new-app.sh --apply <slug> <Module> "<Product name>" <domain> <port>    # makes them (safe to run again)
```

It makes `../<slug>` (tokens replaced, `PLATFORM.md` and `lib/lccz` copied in, `git init`, `mix deps.get`), writes
`identity/blueprints/<slug>.yaml`, and adds the app to the lists below; whatever it can't do safely it prints.
Claude's `new-app` skill (hub repo) runs the whole checklist. Steps marked **owner** need the owner's accounts
or the server; everything else an agent does in the repos. In order:

1. **Repo.** `ops/new-app.sh`; build the features on the template (this file, the app's `CLAUDE.md`); make
   `HubSummary` about the app; `mix precommit` green; first commit (signed: new-app sets the repo up with the
   release key, §5.4). **Owner:** create the GitHub repo (private), push; turn on Dependabot security alerts.
2. **Identity.** Commit `identity/blueprints/<slug>.yaml` (groups `<slug>-users`, `-admins`, `-superadmins`,
   `-requests`; strict redirect URIs; back-channel `logout_uri` `http://<slug>:<port>/auth/oidc/backchannel`) and its
   blocks in `hub-access.yaml` and `.env.example`. **Owner, on the server, before pulling identity:** append
   `<SLUG>_URL`, `<SLUG>_OIDC_CLIENT_ID` and `<SLUG>_OIDC_CLIENT_SECRET` (generated there: `openssl rand -hex 32`) to
   `/opt/identity/.env`; pull; restart; apply `<slug>.yaml` and `hub-access.yaml` (§2). **Owner:** put `admin` in
   `<slug>-admins`, yourself in `-admins` and `-superadmins`, people in `-users`.
3. **Server.** **Owner:** DNS: an A record for the domain → the server's IP in Cloudflare, **proxied** (orange cloud:
   `ops/harden.sh` lets web ports in only from Cloudflare, so an unproxied name doesn't answer). **Owner:** a deploy
   key on the server (`ssh-keygen -t ed25519 -f ~/.ssh/<slug>_deploy`, `Host github-<slug>` in `~/.ssh/config`),
   added read-only to the repo; `git clone` into `/opt/<slug>`; `/opt/<slug>/.env` from `.env.example` with secrets
   generated on the server (the client secret = identity's). Then cut `v0.1.0` (the `release` skill); pushing it
   deploys once `ops/autodeploy.sh` lists the app (or `./scripts/deploy.sh` the first time).
4. **Hub.** `ops/autodeploy.sh`, `zone.sh` and `bootstrap.sh` list it (new-app); the hub's `compose.yaml` /
   `compose.prod.yaml` pass `HUB_<SLUG>_SUMMARY_URL/_SECRET`. A place on the map is a small hub change, by hand:
   the `Hub.Apps` entry (new-app prints it), its illustration in `HubWeb.Art`, the map's tests, and its place in
   the webring (`Lccz.Webring`, then the faint ◀ 🥟 ▶ in the app's own footer: §3). **Owner:**
   `HUB_<SLUG>_SUMMARY_SECRET` in `/opt/hub/.env` = `<SLUG>_HUB_SECRET` in `/opt/<slug>/.env` (generated on the server).
   Release the hub.
5. **Monitoring.** `ops/healthcheck.sh` (new-app: the site's `/api/health`, its containers, error and connection
   checks, certificate, and a new registrable domain). **Owner:** an UptimeRobot monitor for `https://<domain>/api/health`.
6. **Backups.** `ops/backup.sh`, `restore.sh`, `restore-drill.sh` get its `pg_dump` part (new-app; files beyond the
   database need their paths added by hand, like Rule Maven's). After its first night, `ops/restore-drill.sh <slug>`
   on the server.
7. **Dev zone.** `dev/compose.yaml`, `dev/traefik/dynamic.yaml`, `dev/native.sh`, `dev/setup.sh`, `dev/up.sh`,
   `ops/pull-prod-all.sh` (new-app); then `hub/dev/setup.sh` and `hub/dev/up.sh <slug>`.
8. **Docs.** The table in §1, the addresses in §9, the backup table in §10; `OPERATIONS.md` §1 (diagram and table),
   §4 (restore list), §8 (costs: a new domain), §11 (UptimeRobot list). Then `ops/sync-platform.sh` (it learns the
   new repo from new-app) and commit every repo.

Never deploy (push a release) unless the owner asks.

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
- **Prod is read-only:** `pg_dump`. Files **mirror** prod by rsync
  (only changes travel; files prod no longer has are removed locally; regenerable caches like `images/sized` stay). **The local copy is kept first** (`data/backups/local-*`, or `identity/backups/`), and each
  script prints how to go back. Prod dumps are deleted once restored.
- **Each script refuses** if its dev server is running (port in use) or the database is open: swapping a database
  under a running server corrupts it.
- **Code ahead of prod:** migrations newer than prod run on the next dev start (Rule Maven's script runs them).
- **What lands where:** identity → local Authentik's Postgres (docker compose); Drawburn → `drawburn_dev` on the local Postgres;
  Stir & Fold → `stirandfold_dev` on the local Postgres + `data/images`, `data/inbox` (~2.4 GB the first time); Rule Maven →
  `rule_maven_dev` on the local Postgres + `priv/static/uploads`. The hub's database holds only sessions and who has
  seen which release notes: nothing to pull (dev signs in fresh).
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
  `docker compose -f hub/dev/compose.yaml exec <app> mix test`.
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
| `stirandfold` | `pg_dump` (SQLite before v0.61.0), photos, cookbooks, `secret.key` | Stir & Fold's `scripts/offsite-backup.sh` (03:15; its admin page reports on it) |
| `hub` | `pg_dump` (sessions, who has read which notes) | `ops/backup.sh` (03:45) |
| `drawburn` | `pg_dump` (SQLite online backup before v0.8.0) | `ops/backup.sh` |
| `rulemaven` | `pg_dump` + uploaded files | `ops/backup.sh` |
| `identity` | Authentik `pg_dump` + its media and certs | `ops/backup.sh` |
| `rollcall` | `pg_dump` + uploaded media | `ops/backup.sh` |
| `secrets` | every `/opt/*/.env*`, `/opt/traefik` (config + certificates), `~/.ssh` (deploy keys), the crontab | `ops/backup.sh` |
| `pre-optimize` | Stir & Fold's originals before the 2026-11-16 file optimization (kept for good) | by hand |

Kept: 7 daily, 5 weekly, 12 monthly per tag. `ops/backup.sh` checks 2% of the stored data every Sunday and, when
`BACKUP_PING_URL` is set in `/opt/hub/.env.backup`, pings it after a fully successful night and its `/fail` after
a failed one. Alerts come from healthchecks.io: one check per job, each emailing on a `/fail` or a missed ping —
`BACKUP_PING_URL` (daily), `DRILL_PING_URL` (monthly restore drill, same file) and `STIRANDFOLD_BACKUP_PING_URL`
(Stir & Fold's off-site backup, in `/opt/gourmand/.env.backup`). Log: `~/lccz-backups/backup.log`.

**Restore one thing** (same server or new): `ops/restore.sh <secrets|identity|hub|drawburn|stirandfold|rulemaven|rollcall|all> [snapshot]`

**Prove it** (nothing live is touched): `ops/restore-drill.sh [part...]` restores each part's newest snapshot into a
throwaway folder and its dump into a throwaway Postgres (no network), then compares tables, rows and files with
live and reports restore errors. Cron runs it monthly (04:30 on the 1st) into `~/lccz-backups/drill.log`; the
first drill (2026-11-18) restored every part with no errors.
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

