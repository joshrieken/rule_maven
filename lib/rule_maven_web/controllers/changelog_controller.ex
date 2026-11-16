defmodule RuleMavenWeb.ChangelogController do
  @moduledoc """
  "What's new" (/changelog): the release notes this reader may see. Signed-in users only (the
  running version isn't shown to the public; signed-out visitors go to /login, or `RuleMavenWeb.SilentSignIn`). Opening it marks the newest release with notes for them as seen, which clears the red
  dot on the header's version link. A controller rather than a LiveView so the root layout (the
  header) renders after the mark is saved and shows the dot already gone.
  """
  use RuleMavenWeb, :controller

  alias RuleMaven.{Changelog, Users}

  plug :require_login

  # The newest few releases in full; older ones collapsed, so the page isn't every release at once.
  @open 3

  def show(conn, _params) do
    user = conn.assigns.current_user
    admin? = Users.can?(user, :admin)

    conn =
      case Changelog.mark_seen(user) do
        {:ok, user} -> assign(conn, :current_user, user)
        {:error, _} -> conn
      end

    # Only releases with notes for this reader: most early releases are admin-only, and a
    # run of empty entries would bury the ones that matter to everyone else.
    {recent, older} = admin? |> Changelog.visible_releases() |> Enum.split(@open)

    render(conn, :show,
      page_title: "What's new",
      version: Changelog.app_version(),
      recent: recent,
      older: older
    )
  end

  defp require_login(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> RuleMavenWeb.SilentSignIn.send_to_login("Please log in to see what's new.")
      |> halt()
    end
  end
end
