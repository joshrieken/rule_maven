defmodule RuleMaven.Groups.GroupTest do
  use RuleMaven.DataCase, async: true
  alias RuleMaven.Groups.Group

  test "changeset requires name and owner_id and invite_code" do
    cs = Group.changeset(%Group{}, %{})
    refute cs.valid?
    assert %{name: _, owner_id: _, invite_code: _} = errors_on(cs)
  end

  test "Phoenix.Param encodes id as an opaque hashid token" do
    group = %Group{id: 123}
    token = Phoenix.Param.to_param(group)
    refute token == "123"
    assert {:ok, 123} == RuleMaven.Hashid.decode(token)
  end
end
