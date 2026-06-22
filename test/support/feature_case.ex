defmodule RuleMavenWeb.FeatureCase do
  @moduledoc """
  Test case for Wallaby feature/E2E tests.

  The Phoenix endpoint runs on port 4003 (configured in config/test.exs
  with server: true). Tests use shared Ecto sandbox since the browser
  runs in a separate OS process.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature

      import Wallaby.Browser
      import Wallaby.Query
      import RuleMavenWeb.FeatureCase

      alias RuleMaven.Repo

      setup :setup_sandbox
    end
  end

  def setup_sandbox(_context) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(RuleMaven.Repo, shared: true)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    :ok
  end
end
