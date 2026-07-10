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
end
