defmodule RuleMavenWeb.FeatureCase do
  @moduledoc """
  Test case for Wallaby feature/E2E tests.

  The Phoenix endpoint runs on port 4003 (config/test.exs, `server: true`).

  Sandbox: `use Wallaby.Feature` checks the app's ecto_repos into this test
  process's Ecto sandbox and passes the connection metadata to the browser
  session, and the `Phoenix.Ecto.SQL.Sandbox` endpoint plug (test-only) joins
  each browser request to that same connection. So feature-created rows roll
  back with the test instead of committing. Requires `config :wallaby, otp_app`
  and `config :rule_maven, sql_sandbox: true` — both in config/test.exs.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature

      import Wallaby.Browser
      import Wallaby.Query
      import RuleMavenWeb.FeatureCase

      alias RuleMaven.Repo
    end
  end
end
