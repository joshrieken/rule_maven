defmodule Mix.Tasks.RuleMaven.LinkSso do
  @shortdoc "Links an existing account to its single sign-on account (migration)"

  @moduledoc """
  Links an existing Rule Maven account to a person's account at the shared sign-in (Authentik),
  so their first sign-on lands in their existing account instead of a new one. Sign-on never
  matches accounts by email or username; this (or the "Link your … account" button on the
  Settings page, while signed in) is how existing accounts move over.

      mix rule_maven.link_sso --list               # every account, linked or not
      mix rule_maven.link_sso USERNAME SUB         # link (SUB = the user's UID in Authentik's admin)
      mix rule_maven.link_sso USERNAME --unlink

  In production: `bin/prod mix rule_maven.link_sso …`.
  """

  use Mix.Task

  alias RuleMaven.Auth.SignOn
  alias RuleMaven.Users

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["--list"] -> list()
      [username, "--unlink"] -> link(username, nil)
      [username, sub] -> link(username, sub)
      _ -> Mix.raise("Usage: mix rule_maven.link_sso USERNAME SUB | USERNAME --unlink | --list")
    end
  end

  defp list do
    for user <- Enum.sort_by(Users.list_users(), &String.downcase(&1.username)) do
      Mix.shell().info("#{user.username}\t#{user.email}\t#{user.role}\t#{user.oidc_sub || "-"}")
    end
  end

  defp link(username, sub) do
    user = Users.get_user_by_username(username) || Mix.raise("No user named #{username}")

    case SignOn.link_user(user, sub) do
      {:ok, updated} ->
        RuleMaven.Audit.log(updated, "user.sign_on_linked",
          target_type: "user",
          target_id: updated.id,
          target_label: updated.username,
          metadata: %{"via" => "mix task", "unlinked" => is_nil(sub)}
        )

        if sub,
          do: Mix.shell().info("Linked #{updated.username} to sign-on id #{updated.oidc_sub}."),
          else: Mix.shell().info("Unlinked #{updated.username}.")

      {:error, message} ->
        Mix.raise(message)
    end
  end
end
