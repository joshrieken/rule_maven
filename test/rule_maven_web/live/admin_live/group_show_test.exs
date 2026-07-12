defmodule RuleMavenWeb.AdminLive.GroupShowTest do
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
    user = create_user("gshow_plain")
    owner = create_user("gshow_owner0")
    group = group_fixture(owner)

    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> login(user) |> live(~p"/admin/groups/#{group}")
  end

  test "an unknown token redirects to the groups list", %{conn: conn} do
    admin = create_admin("gshow_unknown_admin")
    conn = login(conn, admin)

    {:ok, _view, _html} =
      conn
      |> live(~p"/admin/groups/not-a-real-token")
      |> follow_redirect(conn, ~p"/admin/groups")
  end

  test "admin can view a group they are not a member of, and sees an admin-view banner", %{
    conn: conn
  } do
    admin = create_admin("gshow_view_admin")
    owner = create_user("gshow_view_owner")
    group = group_fixture(owner, %{name: "Viewable Crew"})

    {:ok, _view, html} = conn |> login(admin) |> live(~p"/admin/groups/#{group}")

    assert html =~ "Viewable Crew"
    assert html =~ owner.username
    assert html =~ "Admin view"
  end

  test "admin can rename a group they are not a member of", %{conn: conn} do
    admin = create_admin("gshow_rename_admin")
    owner = create_user("gshow_rename_owner")
    group = group_fixture(owner, %{name: "Old Crew Name"})

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/groups/#{group}")

    view
    |> form("#admin-rename-group", group: %{name: "New Crew Name"})
    |> render_submit()

    assert Groups.get_group_by_token(Phoenix.Param.to_param(group)).name == "New Crew Name"

    entries = Audit.list(action: "group.rename")
    assert Enum.any?(entries, &(&1.target_id == group.id and &1.actor_id == admin.id))
  end

  test "admin can remove a member without being in the group", %{conn: conn} do
    admin = create_admin("gshow_remove_admin")
    owner = create_user("gshow_remove_owner")
    group = group_fixture(owner)
    member = create_user("gshow_remove_member")
    {:ok, _} = Groups.join_by_code(member, group.invite_code)

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/groups/#{group}")

    view
    |> element("[phx-click=remove_member][phx-value-user_id='#{member.id}']")
    |> render_click()

    refute Groups.member?(member, group)

    entries = Audit.list(action: "group.remove_member")
    assert Enum.any?(entries, &(&1.target_id == group.id and &1.actor_id == admin.id))
  end

  test "admin can transfer ownership without being in the group", %{conn: conn} do
    admin = create_admin("gshow_transfer_admin")
    owner = create_user("gshow_transfer_owner")
    group = group_fixture(owner)
    member = create_user("gshow_transfer_member")
    {:ok, _} = Groups.join_by_code(member, group.invite_code)

    {:ok, view, _html} = conn |> login(admin) |> live(~p"/admin/groups/#{group}")

    view
    |> element("[phx-click=transfer_ownership][phx-value-user_id='#{member.id}']")
    |> render_click()

    updated = Groups.get_group_by_token(Phoenix.Param.to_param(group))
    assert Groups.role_of(member, updated) == "owner"

    entries = Audit.list(action: "group.transfer_ownership")
    assert Enum.any?(entries, &(&1.target_id == group.id and &1.actor_id == admin.id))
  end

  test "admin can delete a group and is redirected to the groups list", %{conn: conn} do
    admin = create_admin("gshow_delete_admin")
    owner = create_user("gshow_delete_owner")
    group = group_fixture(owner, %{name: "Deletable Crew"})
    conn = login(conn, admin)

    {:ok, view, _html} = live(conn, ~p"/admin/groups/#{group}")

    {:ok, _view, html} =
      view
      |> element("[phx-click=delete_group]")
      |> render_click()
      |> follow_redirect(conn, ~p"/admin/groups")

    assert html =~ "deleted"
    assert Groups.get_group_by_token(Phoenix.Param.to_param(group)) == nil
  end
end
