defmodule RuleMaven.Flags do
  @moduledoc """
  Thin facade over `fun_with_flags`. Every call validates the flag id against
  `RuleMaven.Flags.Registry`, so a typo raises instead of silently reading the
  library's "no row means false" default.

  Admin bypass is a group gate, not application code: `enable_for_admins/1`
  plus a disabled boolean means "off for everyone, on for admins", because
  `fun_with_flags` gate precedence puts group above boolean.
  """

  import Ecto.Query, only: [from: 2]

  alias RuleMaven.Flags.Registry
  alias RuleMaven.Flags.ExperimentAssignment

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
  Remove the `"user:<id>"` actor gate by raw id, without needing a live
  `%RuleMaven.Users.User{}` struct. Used to clear orphaned grants left behind
  by a deleted user, whose gate would otherwise be un-revokable through the
  normal `revoke_actor/2` path.
  """
  def revoke_actor_id(flag, user_id) when is_integer(user_id) do
    Registry.fetch!(flag)
    FunWithFlags.clear(flag, for_actor: %RuleMaven.Flags.OrphanUserActor{id: user_id})
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

  @doc """
  The experiment variant for `user`, recording first exposure. `:treatment` iff the
  flag's gate is on for the user, else `:control`. Requires a `kind: :experiment` flag.
  A nil user is `:control` and is not recorded.

  The returned variant reflects the live gate at call time; the recorded assignment
  is frozen at first exposure, so the two can diverge if the gate changes between a
  user's exposures (first-exposure-wins for the record).
  """
  def variant(flag, user \\ nil)

  def variant(flag, nil) do
    ensure_experiment!(flag)
    :control
  end

  def variant(flag, %RuleMaven.Users.User{} = user) do
    ensure_experiment!(flag)
    variant = if FunWithFlags.enabled?(flag, for: user), do: :treatment, else: :control
    record_assignment(user.id, flag, variant)
    variant
  end

  def variant(_flag, other) do
    raise ArgumentError, "variant/2 expects a %RuleMaven.Users.User{} or nil, got: #{inspect(other)}"
  end

  @doc "Assignment counts per variant. %{control: n, treatment: m}."
  def assignment_counts(flag) do
    Registry.fetch!(flag)

    rows =
      RuleMaven.Repo.all(
        from a in ExperimentAssignment,
          where: a.experiment == ^to_string(flag),
          group_by: a.variant,
          select: {a.variant, count(a.id)}
      )
      |> Map.new()

    %{control: Map.get(rows, "control", 0), treatment: Map.get(rows, "treatment", 0)}
  end

  defp ensure_experiment!(flag) do
    case Registry.fetch!(flag) do
      %{kind: :experiment} -> :ok
      _ -> raise ArgumentError, "variant/2 requires an :experiment flag, got #{inspect(flag)}"
    end
  end

  defp record_assignment(user_id, flag, variant) do
    %ExperimentAssignment{}
    |> ExperimentAssignment.changeset(%{
      user_id: user_id,
      experiment: to_string(flag),
      variant: to_string(variant)
    })
    |> RuleMaven.Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :experiment])
  end
end
