defmodule RuleMavenWeb.GameLive.ToolRegistryTest do
  use ExUnit.Case, async: true
  alias RuleMavenWeb.GameLive.ToolRegistry

  test "every tool has the required keys and a known group" do
    for t <- ToolRegistry.tools() do
      assert is_atom(t.id)
      assert is_binary(t.emoji) and t.emoji != ""
      assert is_binary(t.label) and t.label != ""
      # :group_feed is deliberately not in any Play/Learn menu — its toggle
      # is a dedicated pill in the group selector, shown only while a group
      # is active (see SubBar.group_selector/1).
      assert t.group in [:play, :learn, :group_feed]
    end
  end

  test "ids are unique" do
    ids = ToolRegistry.ids()
    assert length(ids) == length(Enum.uniq(ids))
  end

  test "group/1 returns only tools of that group" do
    assert Enum.all?(ToolRegistry.group(:play), &(&1.group == :play))
    assert Enum.all?(ToolRegistry.group(:learn), &(&1.group == :learn))
  end

  test "valid?/1 and tool/1 agree" do
    assert ToolRegistry.valid?(:turn)
    refute ToolRegistry.valid?(:nope)
    assert ToolRegistry.tool(:turn).emoji == "🕹️"
    assert ToolRegistry.tool(:nope) == nil
  end
end
