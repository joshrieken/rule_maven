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
    conn = put_resp_header(conn, "cache-control", "no-store")
    sub = params["sub"]

    cond do
      not Hub.hub_request?(conn |> get_req_header("authorization") |> List.first()) ->
        error(conn, 401, "Not allowed.")

      not Map.has_key?(params, "sub") ->
        json(conn, %{version: RuleMaven.Changelog.app_version()})

      not is_binary(sub) or sub == "" or byte_size(sub) > Hub.sub_max() ->
        error(conn, 400, "Say who: ?sub=<sign-on id>.")

      summary = Hub.summary(sub) ->
        json(conn, summary)

      true ->
        error(conn, 404, "Nobody here with that sign-on id.")
    end
  end

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
