defmodule RuleMavenWeb.GameLive.ToolRegistry do
  @moduledoc """
  Static descriptor list for the table-tools sub-bar. Drives both the
  Play/Learn group menus (SubBar) and the shared floating panel (ToolPanel).
  Per-tool *state* lives in the LiveView's socket assigns, not here — this is
  presentation metadata only. Adding a tool is one entry here plus a
  `render_tool/1` clause in ToolPanel.
  """

  @tools [
    # Play — do it at the table now
    %{id: :turn, emoji: "🕹️", label: "Turn Wizard", group: :play},
    %{id: :first_player, emoji: "🎲", label: "Who goes first", group: :play},
    %{id: :checklist, emoji: "🧩", label: "Setup checklist", group: :play},
    %{id: :scorepad, emoji: "🏆", label: "Score pad", group: :play},
    %{id: :timer, emoji: "⏱️", label: "Turn timer", group: :play},
    %{id: :expansions, emoji: "📦", label: "Expansions", group: :play},
    # Learn — understand this game
    %{id: :teach, emoji: "⚡", label: "Teach it in 60s", group: :learn},
    %{id: :quiz, emoji: "🎓", label: "Rules quiz", group: :learn},
    %{id: :mistakes, emoji: "⚠️", label: "Rules tables get wrong", group: :learn},
    %{id: :dyk, emoji: "💡", label: "Did you know", group: :learn},
    %{id: :house_rules, emoji: "🏠", label: "House rules", group: :learn},
    # The group question feed: not listed in the Play/Learn menus (`group:
    # :group_feed` matches no `group/2` call in SubBar) — its toggle is a
    # dedicated pill in `group_selector/1`, shown only while a group is
    # active. Registering it here still gets it the shared window chrome
    # (drag/resize desktop, bottom-sheet mobile) for free via ToolPanel.
    %{id: :group_feed, emoji: "📰", label: "Group feed", group: :group_feed}
  ]

  def tools, do: @tools
  def ids, do: Enum.map(@tools, & &1.id)
  def group(g), do: Enum.filter(@tools, &(&1.group == g))
  def tool(id), do: Enum.find(@tools, &(&1.id == id))
  def valid?(id), do: Enum.any?(@tools, &(&1.id == id))

  @doc """
  Whether a tool is both known and enabled for this user. A tool with no
  matching `:tool_<id>` flag in the registry is always visible (fail-open for
  tools we never chose to gate); a tool with a flag defers to `Flags`.
  """
  def visible?(id, user) do
    valid?(id) and flag_allows?(id, user)
  end

  @doc "Tools visible to this user."
  def tools(user), do: Enum.filter(@tools, &visible?(&1.id, user))

  @doc "Tools in a group visible to this user."
  def group(g, user), do: Enum.filter(group(g), &visible?(&1.id, user))

  defp flag_allows?(id, user) do
    flag = :"tool_#{id}"

    if flag in RuleMaven.Flags.Registry.ids() do
      RuleMaven.Flags.enabled?(flag, user)
    else
      true
    end
  end
end
