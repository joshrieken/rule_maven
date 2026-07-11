defmodule RuleMaven.GroupsFixtures do
  def group_fixture(owner, attrs \\ %{}) do
    {:ok, group} = RuleMaven.Groups.create_group(owner, Enum.into(attrs, %{name: "Test Crew"}))
    group
  end
end
