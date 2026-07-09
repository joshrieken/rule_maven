defmodule Mix.Tasks.RuleMaven.GrantSuperadmin do
  @shortdoc "Grants the super_admin role to a user (server-side only)"

  @moduledoc """
  Grants `super_admin` to the account with the given email.

      mix rule_maven.grant_superadmin owner@example.com

  This is the only path that can create a super admin. The admin UI never
  offers the role, the changeset that the web layer uses rejects it, and the
  raw DB editor refuses to write the users table, so shell access to the server
  is required. Revoke with `mix rule_maven.revoke_superadmin`.
  """

  use Mix.Task

  alias RuleMaven.{Repo, Users}
  alias RuleMaven.Users.User

  import Ecto.Query

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [email] -> grant(String.trim(email))
      _ -> Mix.raise("Usage: mix rule_maven.grant_superadmin <email>")
    end
  end

  defp grant(email) do
    user =
      Repo.one(from u in User, where: fragment("lower(?) = lower(?)", u.email, ^email)) ||
        Mix.raise("No user with email #{email}")

    if Users.super_admin?(user) do
      Mix.shell().info("#{user.username} <#{user.email}> is already a super admin.")
    else
      {:ok, updated} = Users.set_super_admin(user, true)

      RuleMaven.Audit.log(updated, "role.grant_superadmin",
        target_type: "user",
        target_id: to_string(updated.id),
        target_label: updated.username,
        metadata: %{"via" => "mix task"}
      )

      Mix.shell().info("Granted super_admin to #{updated.username} <#{updated.email}>.")
    end
  end
end
