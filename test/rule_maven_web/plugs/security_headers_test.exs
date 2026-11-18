defmodule RuleMavenWeb.Plugs.SecurityHeadersTest do
  use RuleMavenWeb.ConnCase, async: true

  test "browser pages get the strict policy with a fresh script nonce", %{conn: conn} do
    first = get(conn, "/login")
    second = get(build_conn(), "/login")
    [csp] = get_resp_header(first, "content-security-policy")

    assert csp =~ "default-src 'none'"
    assert csp =~ ~r/script-src 'self' 'nonce-[A-Za-z0-9+\/=]+'(;|$)/
    refute csp =~ "script-src 'self' 'unsafe-inline'"
    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "base-uri 'none'"
    assert get_resp_header(first, "x-frame-options") == ["DENY"]
    refute get_resp_header(second, "content-security-policy") == [csp]
  end

  test "pages carry no inline scripts or on*= handlers", %{conn: conn} do
    html = conn |> get("/login") |> html_response(200)
    refute html =~ ~r/<script(?![^>]*\bsrc=)[^>]*>/
    refute html =~ ~r/\son[a-z]+=/
  end
end
