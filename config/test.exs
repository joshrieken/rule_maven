import Config

# Worktrees (.claude/worktrees/*) run tests in parallel with the main
# checkout and each other. Give each worktree its own HTTP port and test
# database so concurrent `mix test` runs don't collide on port 4003 or
# share (and clobber) a single rule_maven_test database.
worktree_name =
  case Regex.run(~r{/\.claude/worktrees/([^/]+)}, File.cwd!()) do
    [_, name] -> name
    _ -> nil
  end

test_port = if worktree_name, do: 4010 + :erlang.phash2(worktree_name, 900), else: 4003

db_suffix =
  if worktree_name do
    "_" <> (worktree_name |> String.replace(~r/[^0-9a-zA-Z_]/, "_") |> String.slice(0, 30))
  else
    ""
  end

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :rule_maven, RuleMaven.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "rule_maven_test#{System.get_env("MIX_TEST_PARTITION")}#{db_suffix}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  types: RuleMaven.PostgresTypes

# Run server on dedicated port for Playwright E2E tests.
# Does not conflict with ConnTest (which bypasses HTTP).
config :rule_maven, RuleMavenWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: test_port],
  secret_key_base: "b7nFAn8+dA6MI2uj33v6K6k+vIyQlk7dWyh8J12BgfmiJrfGvF7OtK1rvwlGKsbr",
  server: true

# Bcrypt's default cost (12) burns ~270ms per hash. Tests create hundreds of
# users; the minimum cost keeps them exercising the real hashing path at ~1ms.
config :bcrypt_elixir, log_rounds: 4

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

# The ETS cache is global; disabling it stops flag state leaking across
# sandboxed tests and producing order-dependent failures.
config :fun_with_flags, :cache, enabled: false

# Capture sent emails in-process so tests can assert on them.
config :rule_maven, RuleMaven.Mailer, adapter: Swoosh.Adapters.Test

# Browser E2E tests — dedicated port (4003 in main checkout, per-worktree above)
# Enables the Phoenix.Ecto.SQL.Sandbox plug in the endpoint (test only), so
# browser requests roll back their DB writes instead of committing.
config :rule_maven, sql_sandbox: true

# phoenix_test_playwright drives the browser tests. The Playwright CLI is a
# devDependency in assets/ (npm --prefix assets install); browsers live in the
# shared ~/Library/Caches/ms-playwright, so worktrees need no per-tree setup.
config :phoenix_test,
  otp_app: :rule_maven,
  ecto_repos: [RuleMaven.Repo],
  base_url: "http://localhost:#{test_port}",
  playwright: [
    browser: :chromium,
    assets_dir: Path.expand("../assets", __DIR__),
    headless: true,
    timeout: :timer.seconds(4)
  ]
