defmodule RuleMaven.Release do
  @moduledoc """
  Tasks run inside a production release, where Mix is unavailable:

      bin/rule_maven eval "RuleMaven.Release.migrate()"

  `rel/overlays/bin/migrate` wraps that; the container runs it before every
  start. Feature flags are seeded afterwards against the running app
  (`bin/rule_maven rpc "RuleMaven.Flags.seed_missing()"`, done by
  `scripts/deploy.sh`), so migrating never starts Oban.
  """
  @app :rule_maven

  @doc "Runs pending migrations."
  def migrate do
    Application.ensure_loaded(@app)

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Rolls `repo` back to `version`."
  def rollback(repo, version) do
    Application.ensure_loaded(@app)
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)
end
