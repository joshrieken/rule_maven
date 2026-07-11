ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(RuleMaven.Repo, :manual)

# Browser E2E tests (phoenix_test_playwright): the endpoint must actually
# serve HTTP (config/test.exs sets server: true on a dedicated port). The
# Playwright node CLI lives in assets/node_modules (see config :phoenix_test).
{:ok, _} = Application.ensure_all_started(:rule_maven)

# Starts the shared Playwright browser pool (one chromium instance; each test
# gets its own isolated browser context).
{:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
