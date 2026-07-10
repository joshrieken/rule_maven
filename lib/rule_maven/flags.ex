defmodule RuleMaven.Flags do
  @moduledoc """
  Thin facade over `fun_with_flags`. Every call validates the flag id against
  `RuleMaven.Flags.Registry`, so a typo raises instead of silently reading the
  library's "no row means false" default.

  Admin bypass is a group gate, not application code: `enable_for_admins/1`
  plus a disabled boolean means "off for everyone, on for admins", because
  `fun_with_flags` gate precedence puts group above boolean.
  """

  alias RuleMaven.Flags.Registry

  @doc "Whether `flag` is enabled, optionally for a specific user (nil = anonymous)."
  def enabled?(flag, user \\ nil) do
    Registry.fetch!(flag)
    FunWithFlags.enabled?(flag, for: user)
  end

  @doc "Enable a flag globally, or for an actor/group/percentage via opts."
  def enable(flag, opts \\ []) do
    Registry.fetch!(flag)
    FunWithFlags.enable(flag, opts)
  end

  @doc "Disable a flag globally, or for an actor/group/percentage via opts."
  def disable(flag, opts \\ []) do
    Registry.fetch!(flag)
    FunWithFlags.disable(flag, opts)
  end

  @doc "Grant a flag to admins as a group override, independent of its boolean gate."
  def enable_for_admins(flag) do
    Registry.fetch!(flag)
    FunWithFlags.enable(flag, for_group: "admin")
  end

  @doc "Grant `flag` to a specific user (actor gate). Overrides the boolean/percentage."
  def grant_actor(flag, %RuleMaven.Users.User{} = user) do
    Registry.fetch!(flag)
    FunWithFlags.enable(flag, for_actor: user)
  end

  @doc "Remove a user's actor gate, reverting them to the boolean/percentage outcome."
  def revoke_actor(flag, %RuleMaven.Users.User{} = user) do
    Registry.fetch!(flag)
    FunWithFlags.clear(flag, for_actor: user)
  end

  @doc """
  Set the percentage-of-actors rollout for `flag`. `ratio <= 0` clears the gate;
  `ratio >= 1` raises (100% is the boolean gate's job — `fun_with_flags` rejects 1.0).
  """
  def set_percentage(flag, ratio) when is_number(ratio) do
    Registry.fetch!(flag)

    cond do
      ratio <= 0 -> FunWithFlags.clear(flag, for_percentage: true)
      ratio >= 1 -> raise ArgumentError, "percentage must be < 1.0 (use the boolean toggle for 100%)"
      true -> FunWithFlags.enable(flag, for_percentage_of: {:actors, ratio / 1})
    end
  end

  @doc """
  Normalized view of a flag's gates for display:
  `%{boolean: bool | nil, percentage: float | nil, actors: ["user:<id>", ...]}`.
  """
  def gates(flag) do
    Registry.fetch!(flag)

    gate_list =
      case FunWithFlags.get_flag(flag) do
        %FunWithFlags.Flag{gates: gates} -> gates
        _ -> []
      end

    Enum.reduce(gate_list, %{boolean: nil, percentage: nil, actors: []}, fn gate, acc ->
      case gate do
        %FunWithFlags.Gate{type: :boolean, enabled: e} -> %{acc | boolean: e}
        %FunWithFlags.Gate{type: :percentage_of_actors, for: r} -> %{acc | percentage: r}
        %FunWithFlags.Gate{type: :actor, for: target, enabled: true} -> %{acc | actors: [target | acc.actors]}
        _ -> acc
      end
    end)
  end
end
