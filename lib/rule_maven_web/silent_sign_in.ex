defmodule RuleMavenWeb.SilentSignIn do
  @moduledoc """
  Silent sign-in: someone already signed in to the shared account (the single sign-on
  provider) who opens a page that needs signing in is signed in here without a button or page.

  Where a signed-out visit would be sent to `/login` (`UserLiveAuth`'s `:app` hook on the
  first, HTTP render, via `UserLiveAuth.get_session/1`; `send_to_login/2` in the
  `require_login` plugs of `/changelog` and the cheat sheets, and `AuthPlug.require_admin/2`), it goes
  to `GET /auth/oidc/silent?next=<path>` instead (`silent_path/1`) when ALL of these hold:

    * sign-on is configured;
    * the request is a top-level page navigation: a GET with `sec-fetch-mode: navigate` (or,
      from browsers that don't send it, `Accept: text/html`) — never JSON/API, assets, or the
      LiveView websocket/longpoll;
    * it isn't `/auth/oidc/*`, `/login`, `/health`, `/live`, `/api` or `/assets`;
    * the cookie `rulemaven_sso_tried` is absent.

  `/auth/oidc/silent` sets that cookie (10 minutes) and asks the provider with `prompt=none`;
  whatever the answer, the browser comes back without a loop. Signing out sets it too.
  Anyone else sees exactly the old pages.
  """

  import Plug.Conn

  alias RuleMaven.Auth.Oidc

  @cookie "rulemaven_sso_tried"
  @cookie_max_age 600
  @next_max 2000
  @skip_prefixes [["auth", "oidc"], ["login"], ["health"], ["live"], ["api"], ["assets"]]

  @doc "Name of the cookie that marks a silent sign-in as already tried."
  def cookie, do: @cookie

  @doc """
  Redirects a signed-out visitor who needs to sign in: to the silent sign-in when the request
  qualifies (no message: they may be signed in a moment later), else to `/login` with `message`.
  The caller halts.
  """
  @spec send_to_login(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def send_to_login(conn, message) do
    case silent_path(conn) do
      nil -> conn |> Phoenix.Controller.put_flash(:error, message) |> redirect_to("/login")
      path -> redirect_to(conn, path)
    end
  end

  defp redirect_to(conn, path), do: Phoenix.Controller.redirect(conn, to: path)

  @doc "The silent sign-in address for this request, or nil when it doesn't qualify."
  @spec silent_path(Plug.Conn.t()) :: String.t() | nil
  def silent_path(%Plug.Conn{} = conn) do
    conn = fetch_cookies(conn)

    if Oidc.enabled?() and conn.method == "GET" and navigation?(conn) and
         not skipped_path?(conn.path_info) and not Map.has_key?(conn.req_cookies, @cookie) do
      "/auth/oidc/silent?" <> URI.encode_query(%{"next" => requested(conn)})
    end
  end

  @doc "Marks a silent sign-in as tried for the next 10 minutes (prevents loops)."
  @spec put_tried_cookie(Plug.Conn.t()) :: Plug.Conn.t()
  def put_tried_cookie(conn) do
    put_resp_cookie(conn, @cookie, "1",
      http_only: true,
      same_site: "Lax",
      secure: secure?(),
      path: "/",
      max_age: @cookie_max_age
    )
  end

  @doc """
  A safe place to return to: a relative path starting with a single `/` (no `//`, no
  backslash, no control characters, at most #{@next_max} bytes). Anything else is `/`.
  """
  @spec safe_next(term()) :: String.t()
  def safe_next("/" <> _ = next) do
    if byte_size(next) <= @next_max and not String.starts_with?(next, "//") and
         not String.contains?(next, "\\") and String.valid?(next) and
         not String.match?(next, ~r/[\x00-\x20\x7f]/) do
      next
    else
      "/"
    end
  end

  def safe_next(_), do: "/"

  defp navigation?(conn) do
    case get_req_header(conn, "sec-fetch-mode") do
      [mode | _] ->
        # A top-level page load; frames are left out (their navigations say so in Sec-Fetch-Dest).
        mode == "navigate" and
          get_req_header(conn, "sec-fetch-dest") not in [
            ["iframe"],
            ["frame"],
            ["embed"],
            ["object"]
          ]

      [] ->
        conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "text/html"))
    end
  end

  defp skipped_path?(path_info) do
    Enum.any?(@skip_prefixes, &List.starts_with?(path_info, &1))
  end

  defp requested(conn) do
    case conn.query_string do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
    |> safe_next()
  end

  # Secure in prod (https); dev and tests run over plain http.
  defp secure? do
    :rule_maven |> Application.get_env(:public_url, "") |> String.starts_with?("https://")
  end
end
