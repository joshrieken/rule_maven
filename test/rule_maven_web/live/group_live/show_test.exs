defmodule RuleMavenWeb.GroupLive.ShowTest do
  @moduledoc """
  Task 6, Gate 4 (per-group override): the "Contribute answers to the
  community" toggle on a group's settings page. Owner/admin only — plain
  members neither see the control nor can flip it via a forged event.
  """

  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GroupsFixtures

  alias RuleMaven.Groups

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})

  defp create_user(prefix, attrs \\ %{}) do
    {:ok, user} =
      RuleMaven.Users.create_user(
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

  test "contribution toggle is on by default and visible to the owner", %{conn: conn} do
    owner = create_user("cont_owner")
    grp = group_fixture(owner)
    conn = login(conn, owner)

    {:ok, _lv, html} = live(conn, ~p"/groups/#{grp}")

    assert html =~ "Contribute answers to the community"
    assert html =~ "contribute-toggle"
    assert Groups.contribute_to_community?(grp.id)
  end

  test "an owner can turn off community contribution", %{conn: conn} do
    owner = create_user("cont_off")
    grp = group_fixture(owner)
    conn = login(conn, owner)

    {:ok, lv, _html} = live(conn, ~p"/groups/#{grp}")

    lv |> element("#contribute-toggle") |> render_click()

    refute Groups.contribute_to_community?(grp.id)
  end

  test "an admin can also turn off community contribution", %{conn: conn} do
    owner = create_user("cont_admin_owner")
    grp = group_fixture(owner)
    admin = create_user("cont_admin")
    {:ok, _} = Groups.join_by_code(admin, grp.invite_code)
    {:ok, _} = Groups.set_role(owner, grp, admin.id, "admin")
    conn = login(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/groups/#{grp}")
    lv |> element("#contribute-toggle") |> render_click()

    refute Groups.contribute_to_community?(grp.id)
  end

  test "a plain member does not see the toggle, and firing the event directly is rejected", %{
    conn: conn
  } do
    owner = create_user("cont_member_owner")
    grp = group_fixture(owner)
    member = create_user("cont_member")
    {:ok, _} = Groups.join_by_code(member, grp.invite_code)
    conn = login(conn, member)

    {:ok, lv, html} = live(conn, ~p"/groups/#{grp}")

    refute html =~ "contribute-toggle"

    render_click(lv, "toggle_contribute", %{})

    assert Groups.contribute_to_community?(grp.id)
  end

  test "a plain member calling Groups.set_contribute/3 directly gets :unauthorized", %{
    conn: _conn
  } do
    owner = create_user("cont_direct_owner")
    grp = group_fixture(owner)
    member = create_user("cont_direct_member")
    {:ok, _} = Groups.join_by_code(member, grp.invite_code)

    assert {:error, :unauthorized} = Groups.set_contribute(grp, member, false)
  end
end
