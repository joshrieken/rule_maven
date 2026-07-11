defimpl FunWithFlags.Actor, for: RuleMaven.Users.User do
  def id(%{id: id}), do: "user:#{id}"
end

defmodule RuleMaven.Flags.OrphanUserActor do
  @moduledoc """
  Tags a raw user id as an actor so its `"user:<id>"` gate can be cleared
  without a live `%RuleMaven.Users.User{}` struct (e.g. the user was deleted).
  """
  defstruct [:id]
end

defimpl FunWithFlags.Actor, for: RuleMaven.Flags.OrphanUserActor do
  def id(%{id: id}), do: "user:#{id}"
end

defimpl FunWithFlags.Group, for: RuleMaven.Users.User do
  # Capability, not role string — see the authorization-capabilities rule.
  def in?(user, "admin"), do: RuleMaven.Users.can?(user, :admin)
  def in?(_user, _group), do: false
end
