defmodule RuleMaven.KillSwitchMigrationTest do
  @moduledoc """
  Guards the one-time data migration that moved the two hand-rolled kill
  switches into feature flags, INVERTING polarity: the old `"disabled" == true`
  app_setting must become the flag being OFF, and its absence/`"false"` must
  become the flag being ON. Getting this backwards silently disables asks in
  production, or silently enables them during the outage the switch was flipped
  for — so both directions are asserted.

  The migration arms off `Settings.get/1`; this exercises the same inversion
  the migration applies (`put_boolean(flag, not disabled?)`), armed via the
  low-level `Settings.put/2` so it does not depend on the removed
  `set_asks_disabled/1` setter.
  """
  use RuleMaven.DataCase, async: false

  alias RuleMaven.{Flags, Settings}

  # Mirrors the transform in
  # priv/repo/migrations/20260710220100_migrate_kill_switches_to_flags.exs.
  defp apply_inversion(setting_key, flag) do
    disabled? = Settings.get(setting_key) == "true"
    if disabled?, do: Flags.disable(flag), else: Flags.enable(flag)
  end

  test "old asks_disabled=\"true\" migrates to the :asks flag being OFF" do
    Settings.put("asks_disabled", "true")
    apply_inversion("asks_disabled", :asks)
    refute Flags.enabled?(:asks, nil)
  after
    FunWithFlags.clear(:asks)
  end

  test "absent/\"false\" asks_disabled migrates to the :asks flag being ON" do
    Settings.put("asks_disabled", "false")
    apply_inversion("asks_disabled", :asks)
    assert Flags.enabled?(:asks, nil)
  after
    FunWithFlags.clear(:asks)
  end

  test "old email_disabled=\"true\" migrates to the :outbound_email flag being OFF" do
    Settings.put("email_disabled", "true")
    apply_inversion("email_disabled", :outbound_email)
    refute Flags.enabled?(:outbound_email, nil)
  after
    FunWithFlags.clear(:outbound_email)
  end
end
