defmodule RuleMavenWeb.SessionLifetime do
  @moduledoc """
  How long a signed-in session lasts (on top of suspension and force-logout, which
  `RuleMaven.Users.session_valid?/2` covers).

    * Single sign-on sessions carry `sso_until` (sign-in + `Oidc.session_days/0`, 7 days):
      after that the person signs in again, and the provider re-checks their groups, so
      removing someone's access there takes effect within a week.
    * Password sessions never expire while sign-on is off. Once it is on, one that predates it
      keeps working for #{30} days from its sign-in (time to press "Link your … account"),
      then the person must use sign-on.
  """

  alias RuleMaven.Auth.Oidc

  @password_grace_days 30

  @doc "Days a password session survives once sign-on is configured."
  def password_grace_days, do: @password_grace_days

  @doc "The `sso_until` value for a sign-on session starting at `now` (unix seconds)."
  def sso_until(now \\ System.os_time(:second)), do: now + Oidc.session_days() * 86_400

  @doc "Whether a session with these markers (unix seconds, or nil) is still live at `now`."
  def valid?(sso_until, logged_in_at, now \\ System.os_time(:second))

  def valid?(sso_until, _logged_in_at, now) when is_integer(sso_until), do: now < sso_until

  def valid?(_sso_until, logged_in_at, now) do
    cond do
      not Oidc.enabled?() -> true
      is_integer(logged_in_at) -> now - logged_in_at < @password_grace_days * 86_400
      true -> false
    end
  end
end
