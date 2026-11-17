defmodule Lccz.SilentSignIn do
  @moduledoc """
  Silent sign-in (PLATFORM.md §2): someone already signed in to the shared account who opens a page
  that needs signing in is signed in here without a button or page.

  Where a signed-out visit would be sent to `/login`, it goes to `GET /auth/oidc/silent?next=<path>`
  instead (`silent_path/1`) when ALL of these hold: sign-on is configured; the request is a
  top-level page navigation (a GET with `sec-fetch-mode: navigate`, frames left out, or from
  browsers that don't send it, `Accept: text/html`), never JSON/API, assets or the LiveView socket;
  it isn't `/auth/oidc/*`, `/login`, `/health`, `/live`, `/api` or `/assets`; and the
  `<slug>_sso_tried` cookie is absent. `/auth/oidc/silent` sets that cookie (10 minutes) and asks
  the provider with `prompt=none`; whatever the answer, the browser comes back without a loop.
  Signing out sets it too.

  `use Lccz.SilentSignIn, otp_app: :drawburn, slug: "drawburn", oidc: Drawburn.Auth.Oidc` defines
  `cookie/0`, `silent_path/1`, `send_to_login/2`, `put_tried_cookie/1` and `safe_next/1`.
  """

  import Plug.Conn

  @cookie_max_age 600
  @next_max 2000
  @skip_prefixes [["auth", "oidc"], ["login"], ["health"], ["live"], ["api"], ["assets"]]

  defmacro __using__(opts) do
    app = Keyword.fetch!(opts, :otp_app)
    slug = Keyword.fetch!(opts, :slug)
    oidc = Keyword.fetch!(opts, :oidc)

    quote do
      @doc "Name of the cookie that marks a silent sign-in as already tried."
      def cookie, do: unquote("#{slug}_sso_tried")

      @doc "The silent sign-in address for this request, or nil when it doesn't qualify."
      def silent_path(conn), do: Lccz.SilentSignIn.silent_path(conn, unquote(oidc).enabled?(), cookie())

      @doc "Sends a signed-out visitor to the silent sign-in if it qualifies, else /login with `message`."
      def send_to_login(conn, message), do: Lccz.SilentSignIn.send_to_login(conn, silent_path(conn), message)

      @doc "Marks a silent sign-in as tried for the next 10 minutes (prevents loops)."
      def put_tried_cookie(conn), do: Lccz.SilentSignIn.put_tried_cookie(conn, cookie(), unquote(app))

      @doc "A safe local path to return to, else `/`."
      def safe_next(next), do: Lccz.SilentSignIn.safe_next(next)
    end
  end

  @doc "The silent sign-in address for this request, or nil when it doesn't qualify."
  @spec silent_path(Plug.Conn.t(), boolean(), String.t()) :: String.t() | nil
  def silent_path(%Plug.Conn{} = conn, enabled?, cookie) do
    conn = fetch_cookies(conn)

    if enabled? and conn.method == "GET" and navigation?(conn) and
         not Enum.any?(@skip_prefixes, &List.starts_with?(conn.path_info, &1)) and
         not Map.has_key?(conn.req_cookies, cookie) do
      "/auth/oidc/silent?" <> URI.encode_query(%{"next" => requested(conn)})
    end
  end

  @doc "Redirects to `silent` when there is one (no message), else to `/login` with `message`. The caller halts."
  @spec send_to_login(Plug.Conn.t(), String.t() | nil, String.t()) :: Plug.Conn.t()
  def send_to_login(conn, nil, message),
    do: conn |> Phoenix.Controller.put_flash(:error, message) |> Phoenix.Controller.redirect(to: "/login")

  def send_to_login(conn, silent, _message), do: Phoenix.Controller.redirect(conn, to: silent)

  @doc "Sets the tried cookie (10 minutes); Secure when the app's public URL is https."
  @spec put_tried_cookie(Plug.Conn.t(), String.t(), atom()) :: Plug.Conn.t()
  def put_tried_cookie(conn, cookie, app) do
    secure = app |> Application.get_env(:public_url, "") |> String.starts_with?("https://")

    put_resp_cookie(conn, cookie, "1",
      http_only: true,
      same_site: "Lax",
      secure: secure,
      path: "/",
      max_age: @cookie_max_age
    )
  end

  @doc """
  A safe place to return to: a relative path starting with a single `/` (no `//`, no backslash, no
  control characters, at most #{@next_max} bytes). Anything else is `/`.
  """
  @spec safe_next(term()) :: String.t()
  def safe_next("/" <> _ = next) do
    if byte_size(next) <= @next_max and not String.starts_with?(next, "//") and
         not String.contains?(next, "\\") and String.valid?(next) and
         not String.match?(next, ~r/[\x00-\x20\x7f]/),
       do: next,
       else: "/"
  end

  def safe_next(_), do: "/"

  defp navigation?(conn) do
    case get_req_header(conn, "sec-fetch-mode") do
      # A top-level page load; frames are left out (their navigations say so in Sec-Fetch-Dest).
      [mode | _] ->
        mode == "navigate" and
          get_req_header(conn, "sec-fetch-dest") not in [["iframe"], ["frame"], ["embed"], ["object"]]

      [] ->
        conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "text/html"))
    end
  end

  defp requested(%{query_string: ""} = conn), do: safe_next(conn.request_path)
  defp requested(conn), do: safe_next(conn.request_path <> "?" <> conn.query_string)
end
