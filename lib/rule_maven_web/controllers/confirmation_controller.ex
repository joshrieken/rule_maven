defmodule RuleMavenWeb.ConfirmationController do
  use RuleMavenWeb, :controller

  alias RuleMaven.Users

  @doc "Confirms an account from the emailed token, then redirects home."
  def confirm(conn, %{"token" => token}) do
    case Users.confirm_user(token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Email confirmed — you can now vote on community answers.")
        |> redirect(to: ~p"/")

      :error ->
        conn
        |> put_flash(:error, "That confirmation link is invalid or has expired.")
        |> redirect(to: ~p"/")
    end
  end
end
