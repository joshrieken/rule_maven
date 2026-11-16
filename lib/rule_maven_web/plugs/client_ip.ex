defmodule RuleMavenWeb.Plugs.ClientIp do
  @moduledoc """
  Sets `conn.remote_ip` to the real client in production, where requests
  arrive Client → Cloudflare → Traefik → app. Without this every request looks
  like it came from Traefik, collapsing the per-IP login / magic-link /
  password-reset throttles (`RuleMaven.Auth.LoginThrottle`) into one shared
  bucket anyone could exhaust.

  Trust chain, never trusting a header the client could have set:

    1. Only when the TCP peer is a private address (Traefik on the Docker
       network; the container publishes no port) do we read forwarded headers.
    2. The LAST `x-forwarded-for` hop is the one Traefik appended: the real
       TCP peer that reached the server.
    3. Only when that peer is a Cloudflare edge (published ranges below) do we
       believe `cf-connecting-ip`. Someone hitting the origin directly with a
       forged header just gets their own address.

  Cloudflare ranges: https://www.cloudflare.com/ips-v4 and /ips-v6 (2026-11-15).
  """
  @behaviour Plug
  import Bitwise

  @cloudflare ~w(
    173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18
    108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17
    162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
    2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32
    2a06:98c0::/29 2c0f:f248::/32
  )
  @private ~w(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 ::1/128 fc00::/7)

  @impl true
  def init(opts) do
    Keyword.merge(
      [proxies: Enum.map(@private, &cidr/1), cloudflare: Enum.map(@cloudflare, &cidr/1)],
      opts
    )
  end

  @impl true
  def call(conn, opts) do
    with true <- in_any?(unmap(conn.remote_ip), opts[:proxies]),
         {:ok, peer} <- last_forwarded(conn) do
      %{conn | remote_ip: via_cloudflare(conn, peer, opts[:cloudflare])}
    else
      _ -> conn
    end
  end

  defp last_forwarded(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [] -> :error
      values -> values |> Enum.join(",") |> String.split(",") |> List.last() |> parse()
    end
  end

  defp via_cloudflare(conn, peer, cloudflare) do
    with true <- in_any?(peer, cloudflare),
         [client | _] <- Plug.Conn.get_req_header(conn, "cf-connecting-ip"),
         {:ok, ip} <- parse(client) do
      ip
    else
      _ -> peer
    end
  end

  defp parse(text) do
    case text |> String.trim() |> String.to_charlist() |> :inet.parse_strict_address() do
      {:ok, ip} -> {:ok, unmap(ip)}
      error -> error
    end
  end

  # Bandit listens on `::`, so IPv4 peers arrive IPv4-mapped (`::ffff:a.b.c.d`).
  defp unmap({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  defp unmap(ip), do: ip

  defp cidr(text) do
    [addr, bits] = String.split(text, "/")
    {:ok, ip} = parse(addr)
    {ip, String.to_integer(bits)}
  end

  defp in_any?(ip, ranges), do: Enum.any?(ranges, &in_range?(ip, &1))

  defp in_range?(ip, {net, bits}) when tuple_size(ip) == tuple_size(net) do
    width = if tuple_size(ip) == 4, do: 32, else: 128
    shift = width - bits
    to_int(ip) >>> shift == to_int(net) >>> shift
  end

  defp in_range?(_ip, _range), do: false

  defp to_int({_, _, _, _} = ip),
    do: ip |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< 8 ||| &1))

  defp to_int(ip), do: ip |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< 16 ||| &1))
end
