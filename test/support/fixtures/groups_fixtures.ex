defmodule RuleMaven.GroupsFixtures do
  @moduledoc """
  Test helpers for creating groups (crews) via `RuleMaven.Groups`.
  """

  def group_fixture(owner, attrs \\ %{}) do
    {:ok, group} = RuleMaven.Groups.create_group(owner, Enum.into(attrs, %{name: "Test Crew"}))
    group
  end
end
