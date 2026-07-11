defmodule RuleMaven.Repo.Migrations.SeedGroupFeedFlag do
  use Ecto.Migration
  import Ecto.Query, only: [from: 2]

  # Persistent groups added a 12th table tool (`:group_feed`, the group question
  # feed panel), which means a 12th `tool_*` flag. Same trap as
  # 20260711020000_seed_tool_flags: `RuleMaven.Flags.Registry` declares the flag
  # `default: true`, but `default:` is honored ONLY by `mix rule_maven.flags.sync`
  # — the read path (`FunWithFlags.enabled?/2`) treats a flag with no persisted
  # gate as FALSE. `ToolRegistry.visible?/2` is `valid?(id) and flag_allows?(id, user)`,
  # so without this row the group feed panel would be invisible to every user, in
  # every environment, and the tool<->flag parity test in flags_test.exs fails.
  #
  # Direct `insert_all` rather than the FunWithFlags API because `mix ecto.migrate`
  # does not boot the OTP tree, so the flags cache / PubSub GenServers do not exist.
  # `target` must be "_fwf_none" (the boolean gate's target) or a duplicate row
  # appears beside the one FunWithFlags later writes and the two get OR'd.
  #
  # `on_conflict: :nothing` keeps this idempotent and non-destructive: if an
  # operator has already turned the flag off, it stays off.
  def up do
    repo().insert_all(
      "fun_with_flags_toggles",
      [
        %{
          flag_name: "tool_group_feed",
          gate_type: "boolean",
          target: "_fwf_none",
          enabled: true
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:flag_name, :gate_type, :target]
    )

    :ok
  end

  def down do
    repo().delete_all(
      from(t in "fun_with_flags_toggles",
        where: t.flag_name == "tool_group_feed" and t.gate_type == "boolean"
      )
    )

    :ok
  end
end
