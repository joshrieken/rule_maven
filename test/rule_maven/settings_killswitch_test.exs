defmodule RuleMaven.SettingsKillSwitchTest do
  use RuleMaven.DataCase

  alias RuleMaven.Settings

  test "asks are enabled by default" do
    refute Settings.asks_disabled?()
  end

  test "set_asks_disabled toggles the flag" do
    {:ok, _} = Settings.set_asks_disabled(true)
    assert Settings.asks_disabled?()

    {:ok, _} = Settings.set_asks_disabled(false)
    refute Settings.asks_disabled?()
  end

  test "message falls back to a default, honors a custom value" do
    assert Settings.asks_disabled_message() =~ "paused"

    {:ok, _} = Settings.put("asks_disabled_message", "Back in 10.")
    assert Settings.asks_disabled_message() == "Back in 10."

    {:ok, _} = Settings.put("asks_disabled_message", "")
    assert Settings.asks_disabled_message() =~ "paused"
  end
end
