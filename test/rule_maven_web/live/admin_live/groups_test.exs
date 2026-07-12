defmodule RuleMavenWeb.AdminLive.GroupsTest do
  use RuleMavenWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RuleMaven.GroupsFixtures

  alias RuleMaven.{Audit, Groups, Users}

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      Users.create_user(
        Map.merge(
          %{
            username: "#{prefix}_user",
            email: "#{prefix}_user@test.com",
            password: "password1234"
          },
          attrs
        )
      )

    user
  end

  defp create_admin(prefix) do
    user = create_user(prefix)
    {:ok, admin} = Users.update_user_role(user, "admin")
    admin
  end

  test "a non-admin is redirected away", %{conn: conn} do
    user = create_user("groupsidx_plain")
    assert {:error, {:redirect, %{to: "/"}}} = conn |> login(user) |> live(~p"/admin/groups")
  end

  test "an admin sees every group, including ones they don't belong to", %{conn: conn} do
    admin = create_admin("groupsidx_admin")
    owner = create_user("groupsidx_owner")
    _group = group_fixture(owner, %{name: "Visible Crew"})

    {:ok, _view, html} = conn |> login(admin) |> live(~p"/admin/groups")

    assert html =~ "Visible Crew"
    assert html =~ owner.username
  end

  test "search filters the list by name", %{conn: conn} do
    admin = create_admin("groupsidx_search_admin")
    owner = create_user("groupsidx_search_owner")
    group_fixture(owner, %{name: "Findable Crew"})
    group_fixture(owner, %{name: "Other Crew"})

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/groups")

    html = view |> form("#groups-search", %{"search" => "Findable"}) |> render_change()

    assert html =~ "Findable Crew"
    refute html =~ "Other Crew"
  end

  test "an admin can delete a group they don't belong to, and it's audit-logged", %{conn: conn} do
    admin = create_admin("groupsidx_del_admin")
    owner = create_user("groupsidx_del_owner")
    group = group_fixture(owner, %{name: "Doomed Crew"})

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/groups")

    view |> element("[phx-click=delete_group][phx-value-id='#{group.id}']") |> render_click()

    assert Groups.get_group_by_token(Phoenix.Param.to_param(group)) == nil

    entries = Audit.list(action: "group.delete")
    assert Enum.any?(entries, &(&1.target_id == group.id and &1.actor_id == admin.id))
  end
end
