defmodule RuleMaven.Repo.Migrations.SeedToolFlags do
  use Ecto.Migration

  # The feature-flags feature added a `tool_<id>` flag for all 11 table tools
  # with `default: true` in RuleMaven.Flags.Registry, but nothing ever wrote
  # those rows. `RuleMaven.Flags.enabled?/2` delegates to FunWithFlags, whose
  # "no persisted gate" outcome is FALSE — so the declared default never
  # applied and every table tool (Expansions, House rules, Quiz, Turn Wizard,
  # …) silently disappeared from the sub-bar and the table-context strip for
  # every user, on every environment whose operator did not happen to run
  # `mix rule_maven.flags.sync` by hand. This seeds the missing rows at their
  # declared default so a migrated database matches the registry.
  #
  # Written as a direct `insert_all` rather than FunWithFlags.enable/1 for the
  # same reason as 20260710220100_migrate_kill_switches_to_flags: `mix
  # ecto.migrate` does not boot the OTP tree, so the flags cache / PubSub
  # GenServers the FunWithFlags API calls into do not exist. `target` must be
  # "_fwf_none" — the boolean gate's target — or a duplicate row appears
  # beside the one FunWithFlags later writes, and the two are OR'd together.
  #
  # The flag list is hardcoded (not read from the registry) so this migration
  # stays a fixed historical snapshot. `on_conflict: :nothing` keeps it
  # idempotent and, crucially, non-destructive: a flag an operator has
  # already toggled OFF stays off.
  @tool_flags ~w(
    tool_turn
    tool_first_player
    tool_checklist
    tool_scorepad
    tool_timer
    tool_expansions
    tool_teach
    tool_quiz
    tool_mistakes
    tool_dyk
    tool_house_rules
  )

  def up do
    flush()

    rows =
      Enum.map(@tool_flags, fn flag ->
        %{flag_name: flag, gate_type: "boolean", target: "_fwf_none", enabled: true}
      end)

    repo().insert_all("fun_with_flags_toggles", rows,
      on_conflict: :nothing,
      conflict_target: [:flag_name, :gate_type, :target]
    )
  end

  def down do
    flush()

    repo().query!(
      "DELETE FROM fun_with_flags_toggles WHERE flag_name = ANY($1) AND gate_type = 'boolean'",
      [@tool_flags]
    )
  end
end
