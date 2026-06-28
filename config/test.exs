import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :rule_maven, RuleMaven.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "rule_maven_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  types: RuleMaven.PostgresTypes

# Run server on dedicated port for Wallaby E2E tests.
# Does not conflict with ConnTest (which bypasses HTTP).
config :rule_maven, RuleMavenWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: "b7nFAn8+dA6MI2uj33v6K6k+vIyQlk7dWyh8J12BgfmiJrfGvF7OtK1rvwlGKsbr",
  server: true

# Wallaby E2E tests need the server on a different port.
# feature_case.ex starts the endpoint on this port explicitly.
config :rule_maven, :wallaby, endpoint_port: 4003

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Disable Oban in test — conflicts with Ecto Sandbox
config :rule_maven, Oban, testing: :manual

# Capture sent emails in-process so tests can assert on them.
config :rule_maven, RuleMaven.Mailer, adapter: Swoosh.Adapters.Test

# Wallaby E2E tests — run on port 4003 to avoid conflict with ConnTest (port 4002)
# Chrome/chromedriver paths set in test_helper.exs (platform-dependent)
config :wallaby,
  driver: Wallaby.Chrome,
  screenshot_on_failure: true,
  js_errors: true,
  base_url: "http://localhost:4003"
