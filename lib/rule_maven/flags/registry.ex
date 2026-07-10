defmodule RuleMaven.Flags.Registry do
  @moduledoc """
  Static descriptor list for every feature flag. Same shape and spirit as
  `RuleMavenWeb.GameLive.ToolRegistry`: presentation and governance metadata
  only — the live on/off state lives in `fun_with_flags`, not here.

  `kind` governs a flag's lifecycle:
    * `:ops`        — a kill switch. Permanent by design.
    * `:release`    — a pre-launch gate. Deleted the week it reaches 100%.
    * `:experiment` — a percentage rollout. Deleted when the experiment concludes.
  """

  @tools ~w(turn first_player checklist scorepad timer expansions teach quiz mistakes dyk house_rules)a

  @tool_labels %{
    turn: "Turn Wizard",
    first_player: "Who goes first",
    checklist: "Setup checklist",
    scorepad: "Score pad",
    timer: "Turn timer",
    expansions: "Expansions",
    teach: "Teach it in 60s",
    quiz: "Rules quiz",
    mistakes: "Rules tables get wrong",
    dyk: "Did you know",
    house_rules: "House rules"
  }

  @tool_flags for t <- @tools,
                  do: %{id: :"tool_#{t}", label: @tool_labels[t], kind: :ops, default: true}

  @kill_switches [
    %{
      id: :asks,
      label: "Question answering (LLM asks)",
      kind: :ops,
      default: true,
      admin_bypass: true
    },
    %{id: :outbound_email, label: "Outbound email", kind: :ops, default: true}
  ]

  @flags @tool_flags ++ @kill_switches

  @doc "All flag descriptors."
  def all, do: @flags

  @doc "All flag ids."
  def ids, do: Enum.map(@flags, & &1.id)

  @doc "Descriptors with the given kind."
  def by_kind(kind), do: Enum.filter(@flags, &(&1.kind == kind))

  @doc "Descriptor for an id. Raises `KeyError` if the id is not registered."
  def fetch!(id) do
    Enum.find(@flags, &(&1.id == id)) ||
      raise KeyError, "unregistered feature flag: #{inspect(id)}"
  end
end
