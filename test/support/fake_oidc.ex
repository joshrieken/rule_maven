defmodule RuleMaven.FakeOidc do
  @moduledoc """
  A stand-in OpenID Connect provider for tests, plugged in as Assent's HTTP adapter
  (`config :rule_maven, :oidc_http_adapter`). It serves discovery, a JWKS with one RSA key, and
  a token endpoint that redeems codes registered with `issue_code/2`, checking the PKCE verifier
  against the registered challenge, the client credentials and the redirect URI, then signs an
  RS256 ID token.

  Requests run in the test process (ConnTest dispatches in-process), so registered codes live in
  the process dictionary. Sign-on config is global (`Application.put_env/3`): tests using this
  must be `async: false`.
  """

  @behaviour Assent.HTTPAdapter

  alias Assent.HTTPAdapter.HTTPResponse

  @issuer "https://id.test/application/o/rulemaven/"
  @client_id "rulemaven"
  @client_secret "test-client-secret"
  @kid "test-key"

  def issuer, do: @issuer
  def client_id, do: @client_id
  def end_session_endpoint, do: "https://id.test/application/o/rulemaven/end-session/"

  @doc "Turns sign-on on for this test (undone on exit)."
  def configure(extra \\ []) do
    Application.put_env(
      :rule_maven,
      :oidc,
      [issuer: @issuer, client_id: @client_id, client_secret: @client_secret] ++ extra
    )

    Application.put_env(:rule_maven, :oidc_http_adapter, __MODULE__)
    RuleMaven.Auth.Oidc.clear_cache()

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:rule_maven, :oidc)
      Application.delete_env(:rule_maven, :oidc_http_adapter)
      RuleMaven.Auth.Oidc.clear_cache()
    end)

    :ok
  end

  @doc """
  Registers what the token endpoint answers for `code`: `:challenge` (the PKCE code_challenge
  the browser was sent with), `:nonce`, `:claims` (merged over the standard ones), and
  optionally `:key` (`:other` signs with a key not in the JWKS).
  """
  def issue_code(code, opts), do: Process.put({__MODULE__, :code, code}, Map.new(opts))

  @doc "A signed ID token with these claims over sensible defaults (for unit tests)."
  def id_token(claims, key \\ :good) do
    now = System.os_time(:second)

    %{"iss" => @issuer, "aud" => @client_id, "iat" => now, "exp" => now + 300}
    |> Map.merge(claims)
    |> sign(key)
  end

  @impl true
  def request(:get, @issuer <> ".well-known/openid-configuration", _body, _headers, _opts) do
    json(200, %{
      "issuer" => @issuer,
      "authorization_endpoint" => "https://id.test/application/o/authorize/",
      "token_endpoint" => "https://id.test/application/o/token/",
      "userinfo_endpoint" => "https://id.test/application/o/userinfo/",
      "end_session_endpoint" => end_session_endpoint(),
      "jwks_uri" => @issuer <> "jwks/",
      "token_endpoint_auth_methods_supported" => ["client_secret_post", "client_secret_basic"],
      "id_token_signing_alg_values_supported" => ["RS256"]
    })
  end

  def request(:get, @issuer <> "jwks/", _body, _headers, _opts) do
    json(200, %{"keys" => [public_jwk(key(:good))]})
  end

  def request(:post, "https://id.test/application/o/token/", body, headers, _opts) do
    params = URI.decode_query(body)
    registered = Process.get({__MODULE__, :code, params["code"]})

    cond do
      not client_authenticated?(headers) ->
        json(401, %{"error" => "invalid_client"})

      is_nil(registered) ->
        json(400, %{"error" => "invalid_grant"})

      params["redirect_uri"] != RuleMaven.Auth.Oidc.redirect_uri() ->
        json(400, %{"error" => "invalid_grant", "error_description" => "redirect_uri"})

      challenge(params["code_verifier"]) != registered[:challenge] ->
        json(400, %{"error" => "invalid_grant", "error_description" => "PKCE"})

      true ->
        Process.delete({__MODULE__, :code, params["code"]})

        claims =
          %{"sub" => "sub-default", "nonce" => registered[:nonce]}
          |> Map.merge(registered[:claims] || %{})

        json(200, %{
          "access_token" => "access-token",
          "token_type" => "Bearer",
          "expires_in" => 300,
          "id_token" => id_token(claims, registered[:key] || :good)
        })
    end
  end

  def request(method, url, _body, _headers, _opts) do
    {:error, {:unexpected_request, method, url}}
  end

  defp client_authenticated?(headers) do
    expected = "Basic " <> Base.encode64("#{@client_id}:#{@client_secret}")
    Enum.any?(headers, fn {k, v} -> String.downcase(k) == "authorization" and v == expected end)
  end

  defp challenge(nil), do: nil
  defp challenge(verifier), do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  defp json(status, body) do
    {:ok,
     %HTTPResponse{
       status: status,
       headers: [{"content-type", "application/json"}],
       body: Jason.encode!(body)
     }}
  end

  defp sign(claims, which) do
    {:ok, jwt} =
      Assent.JWTAdapter.AssentJWT.sign(claims, "RS256", pem(key(which)),
        json_library: Jason,
        private_key_id: @kid
      )

    jwt
  end

  # Two RSA keys per test run: :good is in the JWKS, :other isn't.
  defp key(which) do
    case :persistent_term.get({__MODULE__, which}, nil) do
      nil ->
        key = :public_key.generate_key({:rsa, 2048, 65_537})
        :persistent_term.put({__MODULE__, which}, key)
        key

      key ->
        key
    end
  end

  defp pem(key) do
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
  end

  defp public_jwk(key) do
    # {:RSAPrivateKey, version, modulus, publicExponent, ...}
    n = elem(key, 2)
    e = elem(key, 3)

    %{
      "kty" => "RSA",
      "kid" => @kid,
      "alg" => "RS256",
      "use" => "sig",
      "n" => Base.url_encode64(:binary.encode_unsigned(n), padding: false),
      "e" => Base.url_encode64(:binary.encode_unsigned(e), padding: false)
    }
  end
end
