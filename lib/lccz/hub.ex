defmodule Lccz.Hub do
  @moduledoc """
  The Low-Cal Calzone Zone hub contract (PLATFORM.md): the hub asks each app, server to server with
  `Authorization: Bearer <APP>_HUB_SECRET`, `GET /api/hub/summary?sub=<sign-on id>` for one person's

      %{level: 0..3, active: boolean, headline: ≤80 chars, detail?: ≤120 chars, version, updated}

  and without `sub`, just `%{version}`. 401 without the secret (always, while it's unset), 400 for
  an empty or oversize `sub`, 404 for nobody with that id (or a paused account). Never cached.
  The app supplies the summary (`serve/3`'s `:summary`); this module is the rest.
  """

  import Plug.Conn

  @headline_max 80
  @detail_max 120
  @sub_max 255

  def headline_max, do: @headline_max
  def detail_max, do: @detail_max
  def sub_max, do: @sub_max

  @doc """
  Answers the hub's request. `opts`: `:secret` (the app's hub secret, nil = refuse all), `:version`
  (the running version), `:summary` (`fn sub -> summary map | nil end`).
  """
  @spec serve(Plug.Conn.t(), map(), keyword()) :: Plug.Conn.t()
  def serve(conn, params, opts) do
    conn = put_resp_header(conn, "cache-control", "no-store")
    sub = params["sub"]

    cond do
      not authorized?(conn |> get_req_header("authorization") |> List.first(), opts[:secret]) ->
        error(conn, 401, "Not allowed.")

      not Map.has_key?(params, "sub") ->
        Phoenix.Controller.json(conn, %{version: opts[:version]})

      not is_binary(sub) or sub == "" or byte_size(sub) > @sub_max ->
        error(conn, 400, "Say who: ?sub=<sign-on id>.")

      summary = opts[:summary].(sub) ->
        Phoenix.Controller.json(conn, summary)

      true ->
        error(conn, 404, "Nobody here with that sign-on id.")
    end
  end

  @doc """
  A summary in the contract's shape: text clipped to its limits, `detail` left out when there's none.
  """
  @spec summary(keyword()) :: map()
  def summary(fields) do
    base = %{
      level: fields |> Keyword.fetch!(:level) |> max(0) |> min(3),
      active: !!Keyword.fetch!(fields, :active),
      headline: clip(Keyword.fetch!(fields, :headline), @headline_max),
      version: Keyword.fetch!(fields, :version),
      updated: !!Keyword.get(fields, :updated, false)
    }

    case fields[:detail] do
      detail when is_binary(detail) and detail != "" -> Map.put(base, :detail, clip(detail, @detail_max))
      _ -> base
    end
  end

  @doc "Text cut to `max` characters, with an ellipsis when cut."
  def clip(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  @doc """
  Is this `Authorization: Bearer <secret>`? Compared in constant time (as SHA-256 digests, so
  lengths don't leak); always false while the secret is unset.
  """
  @spec authorized?(String.t() | nil, String.t() | nil) :: boolean()
  def authorized?(authorization, secret) do
    with secret when is_binary(secret) and secret != "" <- secret,
         value when is_binary(value) <- authorization,
         [_, token] <- Regex.run(~r/\ABearer\s+(\S+)\z/i, String.trim(value)) do
      Plug.Crypto.secure_compare(digest(token), digest(secret))
    else
      _ -> false
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value)

  defp error(conn, status, message), do: conn |> put_status(status) |> Phoenix.Controller.json(%{error: message})
end
