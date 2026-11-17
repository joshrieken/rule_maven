defmodule RuleMavenWeb.SilentSignIn do
  @moduledoc """
  Silent sign-in: someone already signed in to the shared account (the single sign-on
  provider) who opens a page that needs signing in is signed in here without a button or page.

  Where a signed-out visit would be sent to `/login` (`UserLiveAuth`'s `:app` hook on the
  first, HTTP render, via `UserLiveAuth.get_session/1`; `send_to_login/2` in the
  `require_login` plugs of `/changelog` and the cheat sheets, and `AuthPlug.require_admin/2`), it goes
  to `GET /auth/oidc/silent?next=<path>` instead (`silent_path/1`) when ALL of these hold:

    * sign-on is configured;
    * the request is a top-level page navigation: a GET with `sec-fetch-mode: navigate` (or,
      from browsers that don't send it, `Accept: text/html`) — never JSON/API, assets, or the
      LiveView websocket/longpoll;
    * it isn't `/auth/oidc/*`, `/login`, `/health`, `/live`, `/api` or `/assets`;
    * the cookie `rulemaven_sso_tried` is absent.

  `/auth/oidc/silent` sets that cookie (10 minutes) and asks the provider with `prompt=none`;
  whatever the answer, the browser comes back without a loop. Signing out sets it too.
  Anyone else sees exactly the old pages.
  """

  use Lccz.SilentSignIn, otp_app: :rule_maven, slug: "rulemaven", oidc: RuleMaven.Auth.Oidc
end
