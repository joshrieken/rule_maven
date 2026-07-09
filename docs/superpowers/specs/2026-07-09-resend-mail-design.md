# Resend mail delivery — design

Date: 2026-07-09

## Goal

Replace the SendGrid-via-env mail wiring with Resend, make delivery safe-by-default
(never crash, never send when unconfigured), add an admin kill switch, and keep the
dev mailbox viewer workflow.

## Decisions

- **API key stays in env** (`RESEND_API_KEY`), never in the settings DB.
  Dev loads it via direnv: committed `.envrc` sources gitignored `.envrc.local`.
- **`mail_from` moves to Settings** (safe, admin-editable live). Default
  `no-reply@rulemaven.app`. Resend requires a verified-domain sender in prod.
- **Kill switch** `email_disabled` in Settings, toggle in the admin panel next to
  the asks kill switch. When on, deliveries are skipped (logged), callers still
  succeed — email is best-effort.
- **Dev adapter choice** via Settings toggle `mail_dev_live`: off (default) means
  Local adapter + existing `/dev/mailbox` viewer (`Plug.Swoosh.MailboxPreview` —
  kept, not replaced); on means real Resend sends from dev (requires key).
- **No boot-time raise.** Delete the `MAIL_API_KEY`/SendGrid block from
  `config/runtime.exs`. Missing key in prod → skip send + `Logger.warning`.

## Send logic (single choke point)

`RuleMaven.Mailer.deliver_email/1`, called by `UserNotifier` (both emails:
confirmation, password reset):

1. `Settings.email_disabled?()` → `{:ok, :email_disabled}`, log info, no send.
2. Test env → default configured adapter (`Swoosh.Adapters.Test`) so
   `assert_email_sent` keeps working; gating rules 1 applies, 3–5 skipped.
3. Dev env and not `mail_dev_live` → default adapter (Local → `/dev/mailbox`).
4. `RESEND_API_KEY` present → per-call config
   `deliver(email, adapter: Resend.Swoosh.Adapter, api_key: key)`.
5. No key (prod, or dev with `mail_dev_live` on) → `{:ok, :email_unconfigured}`,
   `Logger.warning`, no send.

Env detection: `config :rule_maven, env: config_env()` in `config.exs`,
read via `Application.get_env/2` (no `Mix.env()` at runtime).

## Components touched

- `mix.exs`: add `{:resend, "~> 0.4"}` (official Resend Elixir SDK, ships
  `Resend.Swoosh.Adapter`).
- `RuleMaven.Settings`: `email_disabled?/0`, `set_email_disabled/1`,
  `mail_from/0`, `set_mail_from/1`, `mail_dev_live?/0`, `set_mail_dev_live/1`.
- `RuleMaven.Mailer`: gating `deliver_email/1` wrapper.
- `RuleMaven.Users.UserNotifier`: from-address from `Settings.mail_from/0`
  (drop `MAIL_FROM` env), call `Mailer.deliver_email/1`.
- `config/runtime.exs`: delete SendGrid/raise block. `config/config.exs`: add
  `env:` key.
- `AdminLive.Index`: Email section — kill-switch toggle (mirrors asks toggle),
  mail-from input, dev-live toggle (rendered only when `dev_routes`).
- `.envrc` (committed): `source_env_if_exists .envrc.local`; `.gitignore` gains
  `.envrc.local` (already present) — user adds `export RESEND_API_KEY=...` there.

## Testing

- Settings getters/setters round-trip.
- Mailer gating: kill switch skips; test env delivers via Test adapter
  (`assert_email_sent`); unconfigured path returns `{:ok, :email_unconfigured}`.
- Notifier uses settings `mail_from`.
- Per run-only-necessary-tests rule: mailer/settings/notifier tests only.

## Out of scope

New notification types (digests, answer-ready), HTML email templates, building a
custom mailbox viewer.
