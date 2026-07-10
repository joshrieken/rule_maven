defimpl FunWithFlags.Actor, for: RuleMaven.Users.User do
  def id(%{id: id}), do: "user:#{id}"
end

defimpl FunWithFlags.Group, for: RuleMaven.Users.User do
  # Capability, not role string — see the authorization-capabilities rule.
  def in?(user, "admin"), do: RuleMaven.Users.can?(user, :admin)
  def in?(_user, _group), do: false
end
