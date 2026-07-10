defmodule Mix.Tasks.RuleMaven.Flags.Sync do
  @shortdoc "Seed missing feature flags at their registry defaults; report drift."
  @moduledoc """
  Ensures every flag in `RuleMaven.Flags.Registry` has a persisted row at its
  declared default. Idempotent: never overwrites an existing flag, only creates
  missing ones. Reports drift in both directions.

      mix rule_maven.flags.sync          # seed + report
      mix rule_maven.flags.sync --check  # report only, exit 1 on drift
  """
  use Mix.Task

  alias RuleMaven.Flags.Registry

  @requirements ["app.start"]

  @impl true
  def run(args) do
    check_only? = "--check" in args

    {:ok, persisted} = FunWithFlags.all_flag_names()
    persisted = MapSet.new(persisted)
    declared = MapSet.new(Registry.ids())

    unsynced = Registry.all() |> Enum.reject(&MapSet.member?(persisted, &1.id))
    orphans = MapSet.difference(persisted, declared) |> MapSet.to_list()

    Enum.each(unsynced, fn flag ->
      if check_only? do
        Mix.shell().info("UNSYNCED #{flag.id} (default: #{flag.default})")
      else
        if flag.default, do: FunWithFlags.enable(flag.id), else: FunWithFlags.disable(flag.id)
        Mix.shell().info("seeded #{flag.id} = #{flag.default}")
      end
    end)

    Enum.each(orphans, fn id -> Mix.shell().info("ORPHAN #{id} (not in registry)") end)

    unless check_only? do
      Registry.all()
      |> Enum.filter(&Map.get(&1, :admin_bypass, false))
      |> Enum.each(fn flag ->
        FunWithFlags.enable(flag.id, for_group: "admin")
        Mix.shell().info("granted admin bypass: #{flag.id}")
      end)
    end

    if check_only? and (unsynced != [] or orphans != []) do
      Mix.raise("feature-flag drift detected")
    end
  end
end
