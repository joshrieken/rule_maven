defmodule RuleMavenWeb.PasswordResetController do
  use RuleMavenWeb, :controller

  alias RuleMaven.Users
  alias RuleMaven.Auth.LoginThrottle

  @doc "Form to request a reset link."
  def new(conn, _params) do
    render(conn, :new, email: "", sent: false)
  end

  @doc "Sends the reset link. Always reports success (no account enumeration)."
  def create(conn, %{"reset" => %{"email" => email}}) do
    # Throttle per IP so the endpoint can't be used to email-bomb an inbox. The
    # response is identical whether we send or skip — no enumeration, no signal.
    key = LoginThrottle.key(conn.remote_ip, "pwreset")

    case LoginThrottle.check(key) do
      :ok ->
        LoginThrottle.record_failure(key)
        Users.deliver_password_reset_instructions(
          email,
          &RuleMavenWeb.public_url("/reset-password/#{&1}")
        )

      {:error, _} ->
        :throttled
    end

    render(conn, :new, email: "", sent: true)
  end

  @doc "Form to set a new password (token in the URL)."
  def edit(conn, %{"token" => token}) do
    render(conn, :edit, token: token, error: nil)
  end

  @doc "Applies the new password."
  def update(conn, %{"token" => token, "reset" => params}) do
    %{"password" => password, "password_confirmation" => confirmation} = params

    cond do
      password != confirmation ->
        render(conn, :edit, token: token, error: "Passwords don't match.")

      true ->
        case Users.reset_password(token, password) do
          {:ok, _user} ->
            conn
            |> put_flash(:info, "Password updated — you can log in now.")
            |> redirect(to: ~p"/login")

          {:error, _changeset} ->
            render(conn, :edit, token: token, error: "Password must be 4–128 characters.")

          :error ->
            conn
            |> put_flash(:error, "That reset link is invalid or has expired.")
            |> redirect(to: ~p"/reset-password")
        end
    end
  end
end
