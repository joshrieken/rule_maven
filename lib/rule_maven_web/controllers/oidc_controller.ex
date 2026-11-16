defmodule RuleMavenWeb.OidcController do
  @moduledoc """
  Single sign-on endpoints (protocol in `RuleMaven.Auth.Oidc`, decisions in
  `RuleMaven.Auth.SignOn`).

    * `POST /auth/oidc` (`mode` = "login" | "link", CSRF-protected): remembers the attempt in the
      session and sends the browser to the provider.
    * `GET /auth/oidc/callback`: the provider sends the browser back here. One use per attempt.

  The ID token is kept in a signed, httpOnly cookie (`id_token_cookie/0`) so signing out can end
  the provider's session too. Every failure goes to the next page as a flash, never in the URL.
  """
  use RuleMavenWeb, :controller

  require Logger

  alias RuleMaven.Audit
  alias RuleMaven.Auth.{Oidc, SignOn}
  alias RuleMavenWeb.SessionLifetime

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

  def callback(conn, params) do
    pending = get_session(conn, @pending_key)
    conn = delete_session(conn, @pending_key)

    case Oidc.settings() do
      nil ->
        redirect(conn, to: ~p"/login")

      settings ->
        case Oidc.finish_sign_in(settings, pending, params) do
          {:ok, %{mode: mode} = done} ->
            finish(conn, settings, mode, done)

          {:error, message} ->
            fail(conn, message, mode_of(pending))
        end
    end
  end

  defp finish(conn, settings, :login, %{claims: claims, id_token: id_token}) do
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
        |> put_flash(:info, "Welcome back!")
        |> redirect(to: ~p"/")

      {:error, message} ->
        fail(conn, message, :login)
    end
  end

  defp finish(conn, settings, :link, %{claims: claims}) do
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
