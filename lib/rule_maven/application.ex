defmodule RuleMaven.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RuleMavenWeb.Telemetry,
      RuleMaven.Repo,
      {DNSCluster, query: Application.get_env(:rule_maven, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: RuleMaven.PubSub},
      # HTTP pool for Swoosh API mail adapters (prod). Harmless under the
      # Local/Test adapters used in dev/test.
      {Finch, name: RuleMaven.Finch},
      RuleMaven.Auth.LoginThrottle,
      RuleMaven.LLM.NormalizeCache,
      RuleMaven.LLM.Singleflight,
      RuleMaven.Embed.Cache,
      # ETS caches that subscribe to PubSub invalidation topics at init, so
      # they must start after Phoenix.PubSub. Neither touches the DB at init.
      RuleMaven.Settings.Cache,
      RuleMaven.Users.AuthCache,
      RuleMaven.TableSession,
      RuleMavenWeb.Endpoint
    ]

    children = maybe_add_oban(children)

    opts = [strategy: :one_for_one, name: RuleMaven.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_oban(children) do
    if Application.get_env(:rule_maven, Oban)[:testing] == :manual do
      children
    else
      [{Oban, Application.get_env(:rule_maven, Oban)} | children]
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    RuleMavenWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
