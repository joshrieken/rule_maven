defmodule RuleMavenWeb.OidcController do
  @moduledoc """
  Single sign-on endpoints (protocol in `RuleMaven.Auth.Oidc`, decisions in
  `RuleMaven.Auth.SignOn`).

    * `POST /auth/oidc` (`mode` = "login" | "link", CSRF-protected): remembers the attempt in the
      session and sends the browser to the provider.
    * `GET /auth/oidc/silent?next=<path>`: silent sign-in (`RuleMavenWeb.SilentSignIn`): the
      same flow with `prompt=none`; any failure returns quietly to `/login`, success to `next`.
    * `GET /auth/oidc/callback`: the provider sends the browser back here. One use per attempt.

  The ID token is kept in a signed, httpOnly cookie (`id_token_cookie/0`) so signing out can end
  the provider's session too. Every failure goes to the next page as a flash, never in the URL.
  """
  use RuleMavenWeb, :controller

  require Logger

  alias RuleMaven.Audit
  alias RuleMaven.Auth.{Oidc, SignOn}
  alias RuleMavenWeb.{SessionLifetime, SilentSignIn}

  @pending_key :oidc_pending
  @id_token_cookie "_rule_maven_oidc_id"

  @doc "Name of the cookie holding the last sign-on's ID token (for signing out at the provider)."
  def id_token_cookie, do: @id_token_cookie

  def start(conn, params) do
    mode = if params["mode"] == "link", do: :link, else: :login

    case {Oidc.settings(), mode, conn.assigns[:current_user]} do
      {nil, _, _} ->
        redirect(conn, to: ~p"/login")

      {_settings, :link, nil} ->
        conn
        |> put_flash(:error, "Sign in first, then link your account.")
        |> redirect(to: ~p"/login")

      {settings, mode, _user} ->
        case Oidc.begin_sign_in(settings, mode) do
          {:ok, url, pending} ->
            conn
            |> put_session(@pending_key, pending)
            |> redirect(external: url)

          {:error, message} ->
            conn
            |> put_flash(:error, message)
            |> redirect(to: back_to(mode))
        end
    end
  end

  @doc """
  Silent sign-in. A GET (no CSRF token) is fine here: with `prompt=none` the provider never
  shows a page and can only sign this browser in as the person already signed in there, so a
  forged link can't sign anyone in as someone else. The tried cookie is set first, so whatever
  happens the browser isn't sent round again for 10 minutes.
  """
  def silent(conn, params) do
    conn = SilentSignIn.put_tried_cookie(conn)
    next = SilentSignIn.safe_next(params["next"])

    case {Oidc.settings(), conn.assigns[:current_user]} do
      {_settings, %{}} ->
        redirect(conn, to: next)

      {nil, nil} ->
        redirect(conn, to: ~p"/login")

      {settings, nil} ->
        case Oidc.begin_sign_in(settings, :login, silent: next) do
          {:ok, url, pending} ->
            conn
            |> put_session(@pending_key, pending)
            |> redirect(external: url)

          {:error, _message} ->
            redirect(conn, to: ~p"/login")
        end
    end
  end

  def callback(conn, params) do
    pending = get_session(conn, @pending_key)
    conn = delete_session(conn, @pending_key)

    case Oidc.settings() do
      nil ->
        redirect(conn, to: ~p"/login")

      settings ->
        case Oidc.finish_sign_in(settings, pending, params) do
          {:ok, %{mode: mode} = done} ->
            finish(conn, settings, mode, done, silent_next(pending))

          {:error, message} ->
            fail(conn, message, mode_of(pending), silent_next(pending))
        end
    end
  end

  # A silent attempt's return address (nil for a normal one).
  defp silent_next(%{"silent" => true, "next" => next}), do: SilentSignIn.safe_next(next)
  defp silent_next(_pending), do: nil

  defp finish(conn, settings, :login, %{claims: claims, id_token: id_token}, silent_next) do
    case SignOn.sign_in(claims, sign_on_opts(settings)) do
      {:ok, user} ->
        now = System.os_time(:second)

        conn
        |> configure_session(renew: true)
        |> put_session(:user_id, user.id)
        |> put_session(:logged_in_at, now)
        |> put_session(:sso_until, SessionLifetime.sso_until(now))
        |> put_resp_cookie(@id_token_cookie, id_token,
          sign: true,
          http_only: true,
          same_site: "Lax",
          secure: conn.scheme == :https,
          max_age: Oidc.session_days() * 86_400
        )
        |> signed_in(silent_next)

      {:error, message} ->
        fail(conn, message, :login, silent_next)
    end
  end

  defp finish(conn, settings, :link, %{claims: claims}, _silent_next) do
    case conn.assigns[:current_user] do
      nil ->
        fail(conn, "Sign in first, then link your account.", :login)

      user ->
        case SignOn.link(user, claims, sign_on_opts(settings)) do
          {:ok, linked} ->
            Audit.log(linked, "user.sign_on_linked",
              target_type: "user",
              target_id: linked.id,
              target_label: linked.username
            )

            conn
            |> put_flash(:info, "Linked. You can now sign in with #{settings.name}.")
            |> redirect(to: ~p"/settings")

          {:error, message} ->
            fail(conn, message, :link)
        end
    end
  end

  defp signed_in(conn, nil), do: conn |> put_flash(:info, "Welcome back!") |> redirect(to: ~p"/")
  defp signed_in(conn, next), do: redirect(conn, to: next)

  # A silent attempt fails quietly (login_required, consent_required, access_denied, a refused
  # group, …): the visitor lands where they'd have gone anyway, with no message.
  defp fail(conn, _message, _mode, next) when is_binary(next), do: redirect(conn, to: ~p"/login")
  defp fail(conn, message, mode, nil), do: fail(conn, message, mode)

  defp fail(conn, message, mode) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: back_to(mode))
  end

  defp sign_on_opts(settings), do: [group: settings.group, admin_group: settings.admin_group]

  defp mode_of(%{"mode" => "link"}), do: :link
  defp mode_of(_), do: :login

  defp back_to(:link), do: ~p"/settings"
  defp back_to(:login), do: ~p"/login"
end
