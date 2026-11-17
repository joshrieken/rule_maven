defmodule RuleMaven.Auth.Oidc do
  @moduledoc """
  Single sign-on through the shared OpenID Connect provider (Authentik, `../identity`, one
  blueprint per app). When configured it is the ONLY way in: password login, registration,
  password reset, sign-in links and email confirmation all refuse (`RuleMavenWeb.Plugs.PasswordAuth`).
  Without it the app keeps its own password accounts (dev, tests).

  The protocol is the zone's shared `Lccz.Oidc` (via `Assent.Strategy.OIDC`): authorization code flow with
  PKCE (S256) + state + nonce; the ID token's signature (provider JWKS, RS256), issuer, audience,
  expiry and nonce are verified by Assent. Who may sign in, and as whom, is decided by
  `RuleMaven.Auth.SignOn`.

  Configured from the environment (config/runtime.exs → `config :rule_maven, :oidc`):

    RULEMAVEN_OIDC_ISSUER         https://id.lowcalcalzonezone.com/application/o/rulemaven/
    RULEMAVEN_OIDC_CLIENT_ID      rulemaven
    RULEMAVEN_OIDC_CLIENT_SECRET  same value as the identity blueprint's
    RULEMAVEN_OIDC_GROUP          optional, default "rulemaven-users"
    RULEMAVEN_OIDC_ADMIN_GROUP    optional, default "rulemaven-admins"
    RULEMAVEN_OIDC_SUPERADMIN_GROUP  optional: admins also in it are super admins (synced at every
                                  sign-in); unset = super admin is set on the server (mix task)
    RULEMAVEN_OIDC_NAME           optional: "Sign in with <name>"; unset = just "Sign in"

  Return addresses come from configuration (`:public_url`: PUBLIC_URL, else https://PHX_HOST),
  never from request headers: `<public_url>/auth/oidc/callback` and, after signing out at the
  provider, `<public_url>/login` (both registered in the blueprint).
  """

  use Lccz.Oidc, otp_app: :rule_maven, slug: "rulemaven"
end
