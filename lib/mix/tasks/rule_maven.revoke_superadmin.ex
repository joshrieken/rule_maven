defmodule Mix.Tasks.RuleMaven.RevokeSuperadmin do
  @shortdoc "Revokes the super_admin role from a user (server-side only)"

  @moduledoc """
  Demotes a super admin back to a regular user.

      mix rule_maven.revoke_superadmin owner@example.com

  Counterpart to `mix rule_maven.grant_superadmin`. Like the grant, it exists
  only as a mix task: no web path can move a user out of `super_admin` either,
  so a compromised admin account cannot lock the owner out.
  """

  use Mix.Task

  alias RuleMaven.{Repo, Users}
  alias RuleMaven.Users.User

  import Ecto.Query

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [email] -> revoke(String.trim(email))
      _ -> Mix.raise("Usage: mix rule_maven.revoke_superadmin <email>")
    end
  end

  defp revoke(email) do
    user =
      Repo.one(from u in User, where: fragment("lower(?) = lower(?)", u.email, ^email)) ||
        Mix.raise("No user with email #{email}")

    if Users.super_admin?(user) do
      {:ok, updated} = Users.set_super_admin(user, false)

      RuleMaven.Audit.log(updated, "role.revoke_superadmin",
        target_type: "user",
        target_id: to_string(updated.id),
        target_label: updated.username,
        metadata: %{"via" => "mix task"}
      )

      Mix.shell().info("Revoked super_admin from #{updated.username} <#{updated.email}>.")
    else
      Mix.shell().info("#{user.username} <#{user.email}> is not a super admin.")
    end
  end
end
