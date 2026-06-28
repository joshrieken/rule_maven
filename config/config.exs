# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :rule_maven,
  ecto_repos: [RuleMaven.Repo],
  generators: [timestamp_type: :utc_datetime]

config :rule_maven, RuleMaven.Repo, types: RuleMaven.PostgresTypes

# Configure the endpoint
config :rule_maven, RuleMavenWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RuleMavenWeb.ErrorHTML, json: RuleMavenWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: RuleMaven.PubSub,
  live_view: [signing_salt: "rtGgFkah"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Mailer. Defaults to the Local (in-memory) adapter — overridden per-env:
# dev keeps Local (preview at /dev/mailbox), test uses Test, prod must set a
# real adapter (SES/SendGrid/SMTP) in runtime.exs.
config :rule_maven, RuleMaven.Mailer, adapter: Swoosh.Adapters.Local

# Disable Swoosh's default API client (Local/Test adapters in dev/test; prod
# wires Finch when a real API adapter is configured).
config :swoosh, :api_client, false

# Configure Oban
config :rule_maven, Oban,
  engine: Oban.Engines.Basic,
  repo: RuleMaven.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Rescues jobs left in `executing` by a node that crashed/restarted mid-run
    # (otherwise they sit forever and strand the UI waiting on them).
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(10)},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", RuleMaven.Workers.DirectPromotionWorker}
     ]}
  ],
  queues: [default: 5, cheatsheet: 2, clustering: 1, cleanup: 2, llm: 3, expansion: 2]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
