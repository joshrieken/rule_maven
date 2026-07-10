defmodule RuleMaven.KillSwitchMigrationTest do
  use RuleMaven.DataCase, async: false

  alias RuleMaven.{Flags, Settings}

  test "disabled=true in settings maps to the flag being OFF" do
    Settings.set_asks_disabled(true)
    migrate()
    refute Flags.enabled?(:asks, nil)
  after
    Settings.set_asks_disabled(false)
    FunWithFlags.clear(:asks)
  end

  test "absent/false setting maps to the flag being ON" do
    Settings.set_asks_disabled(false)
    migrate()
    assert Flags.enabled?(:asks, nil)
  after
    FunWithFlags.clear(:asks)
  end

  # Exercise the same logic the migration uses, without re-running the file.
  defp migrate do
    disabled? = Settings.get("asks_disabled") == "true"
    if disabled?, do: FunWithFlags.disable(:asks), else: FunWithFlags.enable(:asks)
  end
end
