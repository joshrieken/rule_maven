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

# Runtime env marker so Mailer can branch dev/test/prod without Mix.env().
config :rule_maven, env: config_env()

# Mailer. Default adapter is Local (preview at /dev/mailbox); test overrides
# to Test. Real sends bypass this: Mailer.deliver_email/1 passes the Resend
# adapter per-call when a Resend key is configured (Settings, falls back to
# RESEND_API_KEY).
config :rule_maven, RuleMaven.Mailer, adapter: Swoosh.Adapters.Local

# Disable Swoosh's default API client (Local/Test adapters don't need one;
# the Resend adapter brings its own HTTP client).
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
       {"*/15 * * * *", RuleMaven.Workers.DirectPromotionWorker},
       # Daily: prune job-log events past the 6-month window + reconcile stale runs.
       {"0 4 * * *", RuleMaven.Workers.JobLogPruneWorker}
     ]}
  ],
  # Queue topology — interactive work never queues behind bulk work:
  #   `ask` — AskWorker only. A user is watching a "Thinking…" spinner, so asks
  #   get their own lanes and never sit behind a 15-minute extraction.
  #   `ingest` — download/extract/embed-chunks: the long-running (up to 15 min)
  #   document ingest pipeline, split out of `default` so it can't head-of-line
  #   block small jobs.
  #   `llm_interactive` — user-facing persona restyles (VoiceWorker), split from
  #   `llm` so a game's ~12 bulk enrichment jobs can't starve a viewer waiting
  #   on a voice.
  #   `llm` — bulk enrichment (quiz, suggestions, categories, etc.).
  #   `default` — small DB-only jobs (tagging, publish checks, question embeds,
  #   vote settlement, readiness, theme palette, log pruning).
  #   `reextract` is intentionally serial (concurrency 1): a "re-extract all
  #   flagged" bulk fans out one job per page, and each runs the costly strong
  #   vision model + critic loop. Processing them one at a time keeps the
  #   progress log readable and bounds the LLM spend/rate instead of firing 5
  #   at once.
  queues: [
    ask: 8,
    ingest: 5,
    default: 5,
    cheatsheet: 2,
    clustering: 1,
    cleanup: 2,
    llm: 3,
    llm_interactive: 3,
    expansion: 2,
    reextract: 1
  ]

# Feature flags — Ecto persistence, ETS cache, PubSub cache-busting.
config :fun_with_flags, :persistence,
  adapter: FunWithFlags.Store.Persistent.Ecto,
  repo: RuleMaven.Repo

config :fun_with_flags, :cache_bust_notifications,
  enabled: true,
  adapter: FunWithFlags.Notifications.PhoenixPubSub,
  client: RuleMaven.PubSub

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
