defmodule RuleMavenWeb.Plugs.PasswordAuth do
  @moduledoc """
  Guards the app's own credential routes (password login, password reset, emailed sign-in
  links, email confirmation, registration's auto-login): while single sign-on is configured
  (`RuleMaven.Auth.Oidc.enabled?/0`) they refuse and send people to /login, where the only way
  in is the sign-on button. The code stays for when sign-on is off (dev, tests).
  """
  import Plug.Conn
  import Phoenix.Controller

  alias RuleMaven.Auth.Oidc

  def init(opts), do: opts

  def call(conn, _opts) do
    case Oidc.settings() do
      nil ->
        conn

      settings ->
        conn
        |> put_flash(:error, refusal(settings))
        |> redirect(to: "/login")
        |> halt()
    end
  end

  @doc "What people are told when they reach a password route while sign-on is on."
  def refusal(settings) do
    "Rule Maven now uses #{article(settings.name)} for everyone: use the #{settings.button} button."
  end

  defp article("single sign-on"), do: "single sign-on"
  defp article(name), do: "your #{name} account"
end
