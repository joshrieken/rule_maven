defmodule RuleMaven.Auth.Oidc do
  @moduledoc """
  Single sign-on through the shared OpenID Connect provider (Authentik, `../identity`, one
  blueprint per app). When configured it is the ONLY way in: password login, registration,
  password reset, sign-in links and email confirmation all refuse (`RuleMavenWeb.Plugs.PasswordAuth`).
  Without it the app keeps its own password accounts (dev, tests).

  This module does the protocol only (via `Assent.Strategy.OIDC`): authorization code flow with
  PKCE (S256) + state + nonce; the ID token's signature (provider JWKS, RS256), issuer, audience,
  expiry and nonce are verified by Assent. Who may sign in, and as whom, is decided by
  `RuleMaven.Auth.SignOn`.

  Configured from the environment (config/runtime.exs → `config :rule_maven, :oidc`):

    RULEMAVEN_OIDC_ISSUER         https://id.lowcalcalzonezone.com/application/o/rulemaven/
    RULEMAVEN_OIDC_CLIENT_ID      rulemaven
    RULEMAVEN_OIDC_CLIENT_SECRET  same value as the identity blueprint's
    RULEMAVEN_OIDC_GROUP          optional, default "rulemaven-users"
    RULEMAVEN_OIDC_ADMIN_GROUP    optional, default "rulemaven-admins"
    RULEMAVEN_OIDC_NAME           optional: "Sign in with <name>"; unset = just "Sign in"

  Return addresses come from configuration (`:public_url`: PUBLIC_URL, else https://PHX_HOST),
  never from request headers: `<public_url>/auth/oidc/callback` and, after signing out at the
  provider, `<public_url>/login` (both registered in the blueprint).
  """

  require Logger

  alias Assent.Strategy.OIDC

  defmodule Settings do
    @moduledoc "Resolved sign-on settings (see `RuleMaven.Auth.Oidc.settings/0`)."
    @enforce_keys [:issuer, :client_id, :client_secret]
    defstruct [
      :issuer,
      :client_id,
      :client_secret,
      group: "rulemaven-users",
      admin_group: "rulemaven-admins",
      # For sentences: "Couldn't reach {name}".
      name: "single sign-on",
      # The main sign-in button's text.
      button: "Sign in"
    ]

    @type t :: %__MODULE__{}
  end

  @session_days 7
  @pending_max_age 600
  @discovery_ttl 3600

  @typedoc "`:login` signs in; `:link` attaches the provider account to the signed-in user."
  @type mode :: :login | :link

  @doc "Days a sign-on session lasts: losing access at the provider takes effect within this."
  def session_days, do: @session_days

  @doc "Seconds a sign-in attempt (the pending state/nonce/verifier) stays valid."
  def pending_max_age, do: @pending_max_age

  @doc "The sign-on settings, or nil when sign-on isn't configured (then passwords work)."
  @spec settings() :: Settings.t() | nil
  def settings do
    case Application.get_env(:rule_maven, :oidc) do
      opts when is_list(opts) -> build_settings(opts)
      _ -> nil
    end
  end

  defp build_settings(opts) do
    with issuer when is_binary(issuer) <- present(opts[:issuer]),
         client_id when is_binary(client_id) <- present(opts[:client_id]),
         secret when is_binary(secret) <- present(opts[:client_secret]) do
      name = present(opts[:name])

      %Settings{
        issuer: issuer,
        client_id: client_id,
        client_secret: secret,
        group: present(opts[:group]) || "rulemaven-users",
        admin_group: present(opts[:admin_group]) || "rulemaven-admins",
        name: name || "single sign-on",
        button: if(name, do: "Sign in with #{name}", else: "Sign in")
      }
    else
      _ -> nil
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil

  @doc "True when sign-on is configured: it is then the only way in."
  def enabled?, do: settings() != nil

  @doc "Where the provider sends people back: `<public_url>/auth/oidc/callback`."
  def redirect_uri, do: public_url() <> "/auth/oidc/callback"

  @doc "Where the provider returns people after signing out there: `<public_url>/login`."
  def post_logout_redirect_uri, do: public_url() <> "/login"

  # Deliberately the deploy-time config, not the admin-editable `Settings.public_url/0`: the
  # redirect URI must match the blueprint exactly, and an admin setting must not be able to send
  # authorization codes elsewhere.
  defp public_url do
    :rule_maven |> Application.fetch_env!(:public_url) |> String.trim_trailing("/")
  end

  @doc """
  Starts a sign-in: returns the provider URL to send the browser to, and the pending attempt
  (state, PKCE verifier, nonce, mode, start time) to keep in the session until the callback.

  `silent: next` (a path already checked by `RuleMavenWeb.SilentSignIn.safe_next/1`) asks the
  provider with `prompt=none` (answer at once: signed in as whoever is signed in there, or an
  error, never a page) and marks the attempt silent, returning to `next`.
  """
  @spec begin_sign_in(Settings.t(), mode(), keyword()) ::
          {:ok, String.t(), map()} | {:error, String.t()}
  def begin_sign_in(%Settings{} = s, mode, opts \\ []) when mode in [:login, :link] do
    nonce = random_token()
    silent = opts[:silent]

    with {:ok, config} <- assent_config(s),
         config = if(silent, do: prompt_none(config), else: config),
         {:ok, %{url: url, session_params: params}} <-
           config |> Keyword.put(:nonce, nonce) |> OIDC.authorize_url() do
      pending = %{
        "state" => params.state,
        "verifier" => params.code_verifier,
        "nonce" => params.nonce,
        "mode" => Atom.to_string(mode),
        "at" => System.os_time(:second)
      }

      pending =
        if silent, do: Map.merge(pending, %{"silent" => true, "next" => silent}), else: pending

      {:ok, url, pending}
    else
      error ->
        Logger.warning("sign-on start failed: #{inspect(error)}")
        {:error, "Couldn't reach #{s.name}. Try again in a minute."}
    end
  end

  @doc """
  Finishes a sign-in: checks the provider's answer against the pending attempt (state, PKCE,
  nonce, age), redeems the code and verifies the ID token. Returns the mode, the ID-token claims
  and the raw ID token (kept for signing out at the provider). Errors are safe to show.
  """
  @spec finish_sign_in(Settings.t(), map() | nil, map(), integer()) ::
          {:ok, %{mode: mode(), claims: map(), id_token: String.t()}} | {:error, String.t()}
  def finish_sign_in(%Settings{} = s, pending, params, now \\ System.os_time(:second)) do
    with {:ok, pending} <- check_pending(pending, now),
         :ok <- check_provider_error(params),
         {:ok, config} <- assent_config(s),
         session_params = %{
           state: pending["state"],
           code_verifier: pending["verifier"],
           nonce: pending["nonce"]
         },
         {:ok, %{user: claims, token: %{"id_token" => id_token}}} when is_binary(id_token) <-
           config |> Keyword.put(:session_params, session_params) |> OIDC.callback(params) do
      {:ok, %{mode: mode(pending["mode"]), claims: claims, id_token: id_token}}
    else
      {:error, {:show, message}} ->
        {:error, message}

      {:error, %Assent.CallbackCSRFError{}} ->
        {:error, "Sign-in got mixed up (it may have started in another tab). Try again."}

      other ->
        callback_failed(s, other)
    end
  end

  defp callback_failed(s, reason) do
    Logger.warning("sign-on callback failed: #{inspect(reason)}")
    {:error, "Sign-in with #{s.name} didn't work. Try again."}
  end

  defp check_pending(%{"state" => st, "verifier" => v, "nonce" => n, "at" => at} = pending, now)
       when is_binary(st) and is_binary(v) and is_binary(n) and is_integer(at) do
    if now - at <= @pending_max_age, do: {:ok, pending}, else: pending_missing()
  end

  defp check_pending(_pending, _now), do: pending_missing()

  defp pending_missing,
    do: {:error, {:show, "Sign-in took too long or started in another browser. Try again."}}

  defp check_provider_error(%{"error" => _}),
    do: {:error, {:show, "The sign-in service said no. Try again, or ask the admin."}}

  defp check_provider_error(_params), do: :ok

  defp prompt_none(config) do
    Keyword.update!(config, :authorization_params, &Keyword.put(&1, :prompt, "none"))
  end

  defp mode("link"), do: :link
  defp mode(_), do: :login

  @doc """
  The provider's end-session URL for this ID token (`id_token_hint`), returning to `/login`.
  Nil when sign-on is off, there's no token, or the provider can't be reached (then only the
  app's own session ends).
  """
  @spec end_session_url(String.t() | nil) :: String.t() | nil
  def end_session_url(id_token) when is_binary(id_token) and id_token != "" do
    with %Settings{} = s <- settings(),
         {:ok, discovery} <- discovery(s),
         endpoint when is_binary(endpoint) <- discovery["end_session_endpoint"] do
      query =
        URI.encode_query(%{
          "id_token_hint" => id_token,
          "post_logout_redirect_uri" => post_logout_redirect_uri()
        })

      separator = if String.contains?(endpoint, "?"), do: "&", else: "?"
      endpoint <> separator <> query
    else
      _ -> nil
    end
  end

  def end_session_url(_), do: nil

  defp assent_config(%Settings{} = s) do
    with {:ok, discovery} <- discovery(s) do
      {:ok,
       [
         client_id: s.client_id,
         client_secret: s.client_secret,
         base_url: s.issuer,
         openid_configuration: discovery,
         redirect_uri: redirect_uri(),
         authorization_params: [scope: "email profile"],
         code_verifier: true,
         http_adapter: http_adapter()
       ]}
    end
  end

  defp http_adapter do
    Application.get_env(
      :rule_maven,
      :oidc_http_adapter,
      {Assent.HTTPAdapter.Req, [receive_timeout: 10_000, retry: false]}
    )
  end

  # Provider metadata (.well-known/openid-configuration), fetched once an hour per issuer and
  # re-fetched after a failure. Its `issuer` must be the configured one (OpenID Discovery §4.3).
  defp discovery(%Settings{issuer: issuer} = s) do
    key = {__MODULE__, :discovery, issuer}
    now = System.monotonic_time(:second)

    case :persistent_term.get(key, nil) do
      {doc, fetched} when now - fetched < @discovery_ttl -> {:ok, doc}
      _ -> fetch_discovery(s, key, now)
    end
  end

  defp fetch_discovery(%Settings{issuer: issuer}, key, now) do
    url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    case Assent.Strategy.http_request(:get, url, nil, [], http_adapter: http_adapter()) do
      {:ok, %{status: 200, body: %{"issuer" => doc_issuer} = doc}} ->
        if String.trim_trailing(doc_issuer, "/") == String.trim_trailing(issuer, "/") do
          :persistent_term.put(key, {doc, now})
          {:ok, doc}
        else
          {:error, {:issuer_mismatch, doc_issuer}}
        end

      other ->
        {:error, {:discovery_failed, other}}
    end
  end

  @doc false
  # Tests: forget cached provider metadata.
  def clear_cache do
    for {{__MODULE__, :discovery, _} = key, _} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    :ok
  end

  defp random_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
