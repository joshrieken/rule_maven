defmodule Lccz.Oidc do
  @moduledoc """
  Single sign-on through the shared OpenID Connect provider (Authentik, `../identity`, one
  blueprint per app; PLATFORM.md §2). When configured it is the only way in.

  The protocol only (via `Assent.Strategy.OIDC`): authorization code flow with PKCE (S256) +
  state + nonce; the ID token's signature (provider JWKS, RS256), issuer, audience, expiry and
  nonce are verified by Assent. Who may sign in, and as whom, is the app's (`Lccz.Groups` decides
  the level). Also checks back-channel logout tokens (sign out everywhere).

  Each app binds it to its config with `use Lccz.Oidc, otp_app: :rule_maven, slug: "rulemaven"`,
  which defines `settings/0`, `enabled?/0`, `begin_sign_in/3`, `finish_sign_in/3,4`,
  `end_session_url/1`, `verify_logout_token/2`, `redirect_uri/0`, `post_logout_redirect_uri/0`,
  `session_days/0`, `pending_max_age/0` and `clear_cache/0` in the using module.

  Config (config/runtime.exs → `config <otp_app>, :oidc, issuer:, client_id:, client_secret:,
  group:, admin_group:, superadmin_group:, name:`), from `<APP>_OIDC_*`; groups default to
  `<slug>-users` / `<slug>-admins`, no super-admin group. `config <otp_app>, :public_url` is where
  the provider sends people back (never request headers): `<public_url>/auth/oidc/callback`, and
  `<public_url>/login` after signing out there. Tests swap the HTTP adapter with
  `config <otp_app>, :oidc_http_adapter`.
  """

  require Logger

  alias Assent.Strategy.OIDC

  defmodule Settings do
    @moduledoc "Resolved sign-on settings (`Lccz.Oidc.settings/2`)."
    @enforce_keys [:issuer, :client_id, :client_secret, :group, :admin_group]
    defstruct [
      :issuer,
      :client_id,
      :client_secret,
      :group,
      :admin_group,
      superadmin_group: nil,
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
  @backchannel_event "http://schemas.openid.net/event/backchannel-logout"

  @typedoc "`:login` signs in; `:link` attaches the provider account to the signed-in user."
  @type mode :: :login | :link

  defmacro __using__(opts) do
    app = Keyword.fetch!(opts, :otp_app)
    slug = Keyword.fetch!(opts, :slug)

    quote do
      alias Lccz.Oidc.Settings

      @doc "The sign-on settings, or nil when sign-on isn't configured."
      def settings, do: Lccz.Oidc.settings(unquote(app), unquote(slug))
      @doc "True when sign-on is configured: it is then the only way in."
      def enabled?, do: settings() != nil
      @doc "Where the provider sends people back: `<public_url>/auth/oidc/callback`."
      def redirect_uri, do: Lccz.Oidc.redirect_uri(unquote(app))
      @doc "Where the provider returns people after signing out there: `<public_url>/login`."
      def post_logout_redirect_uri, do: Lccz.Oidc.post_logout_redirect_uri(unquote(app))
      @doc "Days a sign-on session lasts."
      def session_days, do: Lccz.Oidc.session_days()
      @doc "Seconds a sign-in attempt stays valid."
      def pending_max_age, do: Lccz.Oidc.pending_max_age()
      @doc "Starts a sign-in (`Lccz.Oidc.begin_sign_in/4`)."
      def begin_sign_in(s, mode, opts \\ []), do: Lccz.Oidc.begin_sign_in(unquote(app), s, mode, opts)

      @doc "Finishes a sign-in (`Lccz.Oidc.finish_sign_in/5`)."
      def finish_sign_in(s, pending, params, now \\ System.os_time(:second)),
        do: Lccz.Oidc.finish_sign_in(unquote(app), s, pending, params, now)

      @doc "The provider's end-session URL for this ID token, or nil."
      def end_session_url(id_token), do: Lccz.Oidc.end_session_url(unquote(app), settings(), id_token)
      @doc "The person a back-channel logout token is about (`Lccz.Oidc.verify_logout_token/3`)."
      def verify_logout_token(s, token), do: Lccz.Oidc.verify_logout_token(unquote(app), s, token)
      @doc false
      def clear_cache, do: Lccz.Oidc.clear_cache()
    end
  end

  @doc "Days a sign-on session lasts: losing access at the provider takes effect within this."
  def session_days, do: @session_days

  @doc "Seconds a sign-in attempt (the pending state/nonce/verifier) stays valid."
  def pending_max_age, do: @pending_max_age

  @doc "The sign-on settings for `app`, or nil when sign-on isn't configured there."
  @spec settings(atom(), String.t()) :: Settings.t() | nil
  def settings(app, slug) do
    with opts when is_list(opts) <- Application.get_env(app, :oidc),
         issuer when is_binary(issuer) <- present(opts[:issuer]),
         client_id when is_binary(client_id) <- present(opts[:client_id]),
         secret when is_binary(secret) <- present(opts[:client_secret]) do
      name = present(opts[:name])

      %Settings{
        issuer: issuer,
        client_id: client_id,
        client_secret: secret,
        group: present(opts[:group]) || "#{slug}-users",
        admin_group: present(opts[:admin_group]) || "#{slug}-admins",
        superadmin_group: present(opts[:superadmin_group]),
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

  @doc "`<public_url>/auth/oidc/callback`."
  def redirect_uri(app), do: public_url(app) <> "/auth/oidc/callback"

  @doc "`<public_url>/login`."
  def post_logout_redirect_uri(app), do: public_url(app) <> "/login"

  # The deploy-time config, never request headers or an admin setting: the redirect URI must match
  # the blueprint exactly, and nothing editable may send authorization codes elsewhere.
  defp public_url(app), do: app |> Application.fetch_env!(:public_url) |> String.trim_trailing("/")

  @doc """
  Starts a sign-in: the provider URL to send the browser to, and the pending attempt (state, PKCE
  verifier, nonce, mode, start time) to keep in the session until the callback. `silent: next` (a
  path already checked as local) asks with `prompt=none` and marks the attempt silent, returning to
  `next`.
  """
  @spec begin_sign_in(atom(), Settings.t(), mode(), keyword()) ::
          {:ok, String.t(), map()} | {:error, String.t()}
  def begin_sign_in(app, %Settings{} = s, mode, opts \\ []) when mode in [:login, :link] do
    silent = opts[:silent]

    with {:ok, config} <- assent_config(app, s),
         config = if(silent, do: prompt_none(config), else: config),
         {:ok, %{url: url, session_params: params}} <-
           config |> Keyword.put(:nonce, random_token()) |> OIDC.authorize_url() do
      pending = %{
        "state" => params.state,
        "verifier" => params.code_verifier,
        "nonce" => params.nonce,
        "mode" => Atom.to_string(mode),
        "at" => System.os_time(:second)
      }

      {:ok, url, if(silent, do: Map.merge(pending, %{"silent" => true, "next" => silent}), else: pending)}
    else
      error ->
        Logger.warning("sign-on start failed: #{inspect(error)}")
        {:error, "Couldn't reach #{s.name}. Try again in a minute."}
    end
  end

  @doc """
  Finishes a sign-in: checks the provider's answer against the pending attempt (state, PKCE,
  nonce, age), redeems the code and verifies the ID token. Returns the mode, the claims and the raw
  ID token (kept for signing out at the provider). Errors are safe to show.
  """
  @spec finish_sign_in(atom(), Settings.t(), map() | nil, map(), integer()) ::
          {:ok, %{mode: mode(), claims: map(), id_token: String.t()}} | {:error, String.t()}
  def finish_sign_in(app, %Settings{} = s, pending, params, now \\ System.os_time(:second)) do
    with {:ok, pending} <- check_pending(pending, now),
         :ok <- check_provider_error(params),
         {:ok, config} <- assent_config(app, s),
         session_params = %{state: pending["state"], code_verifier: pending["verifier"], nonce: pending["nonce"]},
         {:ok, %{user: claims, token: %{"id_token" => id_token}}} when is_binary(id_token) <-
           config |> Keyword.put(:session_params, session_params) |> OIDC.callback(params) do
      {:ok, %{mode: mode(pending["mode"]), claims: claims, id_token: id_token}}
    else
      {:error, {:show, message}} ->
        {:error, message}

      {:error, %Assent.Strategy.CallbackCSRFError{}} ->
        {:error, "Sign-in got mixed up (it may have started in another tab). Try again."}

      other ->
        Logger.warning("sign-on callback failed: #{inspect(other)}")
        {:error, "Sign-in with #{s.name} didn't work. Try again."}
    end
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

  defp prompt_none(config), do: Keyword.update!(config, :authorization_params, &Keyword.put(&1, :prompt, "none"))

  defp mode("link"), do: :link
  defp mode(_), do: :login

  @doc """
  The provider's end-session URL for this ID token (`id_token_hint`), returning to `/login`. Nil
  when sign-on is off, there's no token, or the provider can't be reached (then only the app's
  own session ends).
  """
  @spec end_session_url(atom(), Settings.t() | nil, String.t() | nil) :: String.t() | nil
  def end_session_url(app, %Settings{} = s, id_token) when is_binary(id_token) and id_token != "" do
    with {:ok, discovery} <- discovery(app, s),
         endpoint when is_binary(endpoint) <- discovery["end_session_endpoint"] do
      query =
        URI.encode_query(%{"id_token_hint" => id_token, "post_logout_redirect_uri" => post_logout_redirect_uri(app)})

      endpoint <> if(String.contains?(endpoint, "?"), do: "&", else: "?") <> query
    else
      _ -> nil
    end
  end

  def end_session_url(_app, _settings, _id_token), do: nil

  @doc """
  The person a back-channel logout token is about (its `sub`), once it checks out (OpenID Connect
  Back-Channel Logout 1.0 §2.6): validated like an ID token (signature from the provider's keys,
  issuer, audience, expiry), carrying the logout event and no nonce, so an ID token can't stand in
  for one. Sign out everywhere, PLATFORM.md §2.
  """
  @spec verify_logout_token(atom(), Settings.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def verify_logout_token(app, %Settings{} = s, token) when is_binary(token) do
    # (No nonce was sent for it, so an empty session_params makes a nonce in the token an error.)
    with {:ok, config} <- assent_config(app, s),
         {:ok, %{claims: claims}} <- OIDC.validate_id_token(Keyword.put(config, :session_params, %{}), token),
         %{@backchannel_event => _} <- claims["events"] || :no_event,
         sub when is_binary(sub) and sub != "" and byte_size(sub) <= 255 <- claims["sub"] do
      {:ok, sub}
    else
      {:error, _} = error -> error
      _ -> {:error, "Not a logout token"}
    end
  end

  def verify_logout_token(_app, _settings, _token), do: {:error, "No logout token"}

  defp assent_config(app, %Settings{} = s) do
    with {:ok, discovery} <- discovery(app, s) do
      {:ok,
       [
         client_id: s.client_id,
         client_secret: s.client_secret,
         base_url: s.issuer,
         openid_configuration: discovery,
         redirect_uri: redirect_uri(app),
         authorization_params: [scope: "email profile"],
         code_verifier: true,
         http_adapter: http_adapter(app)
       ]}
    end
  end

  defp http_adapter(app) do
    Application.get_env(app, :oidc_http_adapter, {Assent.HTTPAdapter.Req, [receive_timeout: 10_000, retry: false]})
  end

  # Provider metadata (.well-known/openid-configuration), fetched once an hour per issuer and
  # re-fetched after a failure. Its `issuer` must be the configured one (OpenID Discovery §4.3).
  defp discovery(app, %Settings{issuer: issuer}) do
    key = {__MODULE__, :discovery, issuer}
    now = System.monotonic_time(:second)

    case :persistent_term.get(key, nil) do
      {doc, fetched} when now - fetched < @discovery_ttl -> {:ok, doc}
      _ -> fetch_discovery(app, issuer, key, now)
    end
  end

  defp fetch_discovery(app, issuer, key, now) do
    url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    case Assent.Strategy.http_request(:get, url, nil, [], http_adapter: http_adapter(app)) do
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
    for {{__MODULE__, :discovery, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
    :ok
  end

  defp random_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
