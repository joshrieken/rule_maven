defmodule RuleMavenWeb.HubController do
  @moduledoc """
  `GET /api/hub/summary?sub=<sign-on id>` for the Low-Cal Calzone Zone hub only (server to
  server, `Authorization: Bearer <RULEMAVEN_HUB_SECRET>`): one person's `RuleMaven.Hub.summary/2`.
  Without `sub`: just `{"version": ...}` (the hub shows every app's version).
  401 without the secret (always, while it's unset), 400 for an empty or oversize `sub`, 404
  for nobody here with that id (or a suspended account). Never cached.
  """
  use RuleMavenWeb, :controller

  alias RuleMaven.Hub

  def summary(conn, params) do
    Lccz.Hub.serve(conn, params,
      secret: Application.get_env(:rule_maven, :hub_secret),
      version: RuleMaven.Changelog.app_version(),
      summary: &Hub.summary/1
    )
  end
end
