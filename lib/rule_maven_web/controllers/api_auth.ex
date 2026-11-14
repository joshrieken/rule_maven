defmodule RuleMavenWeb.ApiAuth do
  @moduledoc """
  Bearer-token gate for `/api/admin`. Resolves `Authorization: Bearer <token>`
  via `Users.get_api_user/1` (valid, unexpired, super admin, not suspended) and
  assigns `:current_user`; anything else is a bare 401 JSON response.
  """
  import Plug.Conn

  alias RuleMaven.Users

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user} <- Users.get_api_user(String.trim(token)) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, ~s({"error":"unauthorized"}))
        |> halt()
    end
  end
end
