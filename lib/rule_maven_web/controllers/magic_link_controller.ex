defmodule RuleMavenWeb.MagicLinkController do
  use RuleMavenWeb, :controller

  alias RuleMaven.Users
  alias RuleMaven.Auth.LoginThrottle

  @doc "Form to request a sign-in link."
  def new(conn, _params) do
    render(conn, :new, email: "", sent: false)
  end

  @doc "Sends the sign-in link. Always reports success (no account enumeration)."
  def create(conn, %{"magic_link" => %{"email" => email}}) do
    # Throttle per IP so the endpoint can't be used to email-bomb an inbox —
    # same shape as PasswordResetController's throttle.
    key = LoginThrottle.key(conn.remote_ip, "magiclink")

    case LoginThrottle.check(key) do
      :ok ->
        LoginThrottle.record_failure(key)

        Users.deliver_magic_link_instructions(
          email,
          &RuleMavenWeb.public_url("/magic-link/#{&1}")
        )

      {:error, _} ->
        :throttled
    end

    render(conn, :new, email: "", sent: true)
  end

  @doc "Consumes the sign-in link and logs the user in."
  def consume(conn, %{"token" => token}) do
    case Users.consume_magic_link(token) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> put_session(:logged_in_at, System.os_time(:second))
        |> put_flash(:info, "Welcome back!")
        |> redirect(to: ~p"/")

      {:error, :suspended} ->
        conn
        |> put_flash(:error, "This account has been suspended.")
        |> redirect(to: ~p"/login")

      :error ->
        conn
        |> put_flash(:error, "That sign-in link is invalid or has expired.")
        |> redirect(to: ~p"/magic-link")
    end
  end
end
