defmodule RuleMavenWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Strict headers on every browser answer, like the other zone apps (PLATFORM.md §6):
  `default-src 'none'`; scripts only from this site (no inline scripts or `on*=` handlers:
  menus close through `data-close-menu`, see app.js); `connect-src` is this site plus its
  websocket (LiveView); images also from BoardGameGeek's image host; forms may go to the
  sign-in service; no framing.

  Styles allow `'unsafe-inline'` because pages and generated game themes use `style=`
  attributes and `<style>` blocks; the Google Fonts stylesheet and font files are allowed.

  Every request gets a fresh nonce in `conn.assigns.csp_nonce`, allowed in `script-src`, so
  the Oban dashboard (`oban_dashboard ... csp_nonce_assign_key: :csp_nonce`) can run its own
  inline scripts. Nothing else should use it.

  The rulebook HTML copies (`RulebookController.html/2`) replace this policy with a sandboxed
  one.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> merge_resp_headers([
      {"content-security-policy", csp(Application.get_env(:rule_maven, :public_url, ""), nonce)},
      {"referrer-policy", "strict-origin-when-cross-origin"},
      {"x-content-type-options", "nosniff"},
      {"x-frame-options", "DENY"}
    ])
  end

  @doc "The Content-Security-Policy for Rule Maven at `public_url`, with `nonce`."
  def csp(public_url, nonce) do
    [
      "default-src 'none'",
      "script-src 'self' 'nonce-#{nonce}'",
      "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
      "font-src 'self' https://fonts.gstatic.com",
      # BoardGameGeek box art (games.image_url)
      "img-src 'self' data: https://cf.geekdo-images.com",
      "connect-src 'self'#{websocket(public_url)}",
      "manifest-src 'self'",
      "worker-src 'self'",
      # dev only: Phoenix's live-reload iframe
      if(RuleMavenWeb.Endpoint.config(:code_reloader), do: "frame-src 'self'"),
      "form-action 'self'#{issuer_origin()}",
      "base-uri 'none'",
      "frame-ancestors 'none'"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp websocket(public_url) do
    case URI.parse(public_url) do
      %URI{scheme: "https", authority: host} when is_binary(host) -> " wss://#{host}"
      %URI{scheme: "http", authority: host} when is_binary(host) -> " ws://#{host}"
      _ -> ""
    end
  end

  defp issuer_origin do
    with opts when is_list(opts) <- Application.get_env(:rule_maven, :oidc),
         issuer when is_binary(issuer) <- opts[:issuer],
         %URI{scheme: scheme, authority: authority}
         when is_binary(scheme) and is_binary(authority) <- URI.parse(issuer) do
      " #{scheme}://#{authority}"
    else
      _ -> ""
    end
  end
end
