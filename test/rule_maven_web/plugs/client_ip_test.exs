defmodule RuleMavenWeb.Plugs.ClientIpTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias RuleMavenWeb.Plugs.ClientIp

  @opts ClientIp.init([])
  @traefik {172, 18, 0, 2}
  @cf_edge "162.158.1.1"

  defp run(peer, headers) do
    conn = conn(:get, "/") |> Map.put(:remote_ip, peer)

    headers
    |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> ClientIp.call(@opts)
  end

  test "behind Traefik via Cloudflare: uses cf-connecting-ip" do
    conn = run(@traefik, [{"x-forwarded-for", @cf_edge}, {"cf-connecting-ip", "203.0.113.9"}])
    assert conn.remote_ip == {203, 0, 113, 9}
  end

  test "IPv6 client via Cloudflare" do
    conn = run(@traefik, [{"x-forwarded-for", @cf_edge}, {"cf-connecting-ip", "2001:db8::1"}])
    assert conn.remote_ip == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
  end

  test "direct to origin with a forged cf-connecting-ip: uses the real peer" do
    conn =
      run(@traefik, [{"x-forwarded-for", "198.51.100.7"}, {"cf-connecting-ip", "203.0.113.9"}])

    assert conn.remote_ip == {198, 51, 100, 7}
  end

  test "only the last x-forwarded-for hop counts (client-supplied entries ignored)" do
    conn =
      run(@traefik, [
        {"x-forwarded-for", "#{@cf_edge}, 198.51.100.7"},
        {"cf-connecting-ip", "203.0.113.9"}
      ])

    assert conn.remote_ip == {198, 51, 100, 7}
  end

  test "public peer: headers are ignored entirely" do
    conn =
      run({198, 51, 100, 7}, [{"x-forwarded-for", "1.2.3.4"}, {"cf-connecting-ip", "5.6.7.8"}])

    assert conn.remote_ip == {198, 51, 100, 7}
  end

  test "private peer without forwarded header: unchanged" do
    assert run(@traefik, []).remote_ip == @traefik
  end

  test "garbage headers: falls back safely" do
    assert run(@traefik, [{"x-forwarded-for", "nope"}]).remote_ip == @traefik

    conn = run(@traefik, [{"x-forwarded-for", @cf_edge}, {"cf-connecting-ip", "nope"}])
    assert conn.remote_ip == {162, 158, 1, 1}
  end
end
