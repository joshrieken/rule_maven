defmodule Mix.Tasks.RuleMaven.ApiToken do
  @shortdoc "Mints or revokes a super admin's /api/admin bearer token"

  @moduledoc """
  Mints a 90-day bearer token for the remote Prepare API (`/api/admin`), or
  revokes all of a user's tokens. Super admins only.

      mix rule_maven.api_token USERNAME
      mix rule_maven.api_token USERNAME --revoke

  The raw token is printed once; only its hash is stored. In a release (no
  mix), call the same functions: `RuleMaven.Users.create_api_token/1` and
  `RuleMaven.Users.revoke_api_tokens/1`.
  """
  use Mix.Task

  alias RuleMaven.Users

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [username] -> mint(user!(username))
      [username, "--revoke"] -> revoke(user!(username))
      _ -> Mix.raise("Usage: mix rule_maven.api_token USERNAME [--revoke]")
    end
  end

  defp user!(username),
    do: Users.get_user_by_username(username) || Mix.raise("No user #{username}")

  defp mint(user) do
    case Users.create_api_token(user) do
      {:ok, token} ->
        RuleMaven.Audit.log(user, "api_token.mint", metadata: %{"via" => "mix task"})
        Mix.shell().info(token)

      {:error, :not_super_admin} ->
        Mix.raise("#{user.username} is not a super admin")
    end
  end

  defp revoke(user) do
    n = Users.revoke_api_tokens(user)
    RuleMaven.Audit.log(user, "api_token.revoke", metadata: %{"via" => "mix task", "count" => n})
    Mix.shell().info("Revoked #{n} token(s) for #{user.username}.")
  end
end
