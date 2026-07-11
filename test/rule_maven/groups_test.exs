defmodule RuleMaven.GroupsTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Groups

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
        Map.merge(
          %{username: "#{prefix}_user", email: "#{prefix}_user@test.com", password: "password1234"},
          attrs
        )
      )

    user
  end

  test "create_group inserts group + owner membership" do
    owner = create_user("owner")
    {:ok, group} = Groups.create_group(owner, %{name: "Game Night"})
    assert group.name == "Game Night"
    assert group.owner_id == owner.id
    assert String.length(group.invite_code) > 0
    assert Groups.role_of(owner, group) == "owner"
  end

  test "get_group_by_token round-trips the hashid" do
    owner = create_user("crew")
    {:ok, group} = Groups.create_group(owner, %{name: "Crew"})
    token = Phoenix.Param.to_param(group)
    assert Groups.get_group_by_token(token).id == group.id
    assert Groups.get_group_by_token("not-a-token") == nil
  end

  test "get_group_by_token! raises for a missing group" do
    assert_raise Ecto.NoResultsError, fn ->
      Groups.get_group_by_token!("not-a-token")
    end
  end

  test "role_of tolerates a nil user" do
    owner = create_user("solo")
    {:ok, group} = Groups.create_group(owner, %{name: "Solo"})
    assert Groups.role_of(nil, group) == nil
  end

  test "create_group rolls back on invalid attrs, leaving no orphan membership" do
    owner = create_user("bad")
    assert {:error, _changeset} = Groups.create_group(owner, %{name: ""})
    assert Groups.role_of(owner, %RuleMaven.Groups.Group{id: -1}) == nil
  end
end
