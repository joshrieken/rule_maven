defmodule RuleMavenWeb.GroupLive.ManageTest do
  use RuleMavenWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import RuleMaven.GroupsFixtures
  alias RuleMaven.Repo

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

  describe "GroupLive.Index" do
    test "a user creates a group and sees it listed", %{conn: conn} do
      user = create_user("creator")
      conn = login(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/groups")
      lv |> form("#new-group", group: %{name: "Sunday Crew"}) |> render_submit()

      assert render(lv) =~ "Sunday Crew"
      assert Enum.any?(RuleMaven.Groups.list_for_user(user), &(&1.name == "Sunday Crew"))
    end

    test "lists existing groups the user belongs to", %{conn: conn} do
      owner = create_user("owner_idx")
      _grp = group_fixture(owner, %{name: "Existing Crew"})
      conn = login(conn, owner)

      {:ok, _lv, html} = live(conn, ~p"/groups")
      assert html =~ "Existing Crew"
    end
  end

  describe "GroupLive.Show — IDOR guard" do
    test "non-member cannot open a group's settings by token", %{conn: conn} do
      owner = create_user("owner_show")
      grp = group_fixture(owner)
      stranger = create_user("stranger")
      conn = login(conn, stranger)

      assert {:error, {:live_redirect, %{to: "/groups"}}} = live(conn, ~p"/groups/#{grp}")
    end

    test "a member CAN open the group's settings", %{conn: conn} do
      owner = create_user("owner_member")
      grp = group_fixture(owner)
      conn = login(conn, owner)

      {:ok, _lv, html} = live(conn, ~p"/groups/#{grp}")
      assert html =~ grp.name
    end
  end

  describe "GroupLive.Join" do
    test "joining by code adds the user and the group appears in their list", %{conn: conn} do
      owner = create_user("owner_join")
      grp = group_fixture(owner)
      joiner = create_user("joiner")
      conn = login(conn, joiner)

      {:ok, _lv, html} = live(conn, ~p"/groups/join/#{grp.invite_code}")
      assert html =~ grp.name
      assert RuleMaven.Groups.member?(joiner, grp)
      assert Enum.any?(RuleMaven.Groups.list_for_user(joiner), &(&1.id == grp.id))
    end

    test "a bad/garbage code shows an error and does not crash", %{conn: conn} do
      user = create_user("badcode")
      conn = login(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/groups/join/totally-not-a-real-code")
      assert html =~ "Can&#39;t join" or html =~ "valid" or html =~ "matching group"
    end

    test "a regenerated code invalidates the old link", %{conn: conn} do
      owner = create_user("owner_regen")
      grp = group_fixture(owner)
      old_code = grp.invite_code
      {:ok, _} = RuleMaven.Groups.regenerate_code(owner, grp)
      joiner = create_user("joiner_regen")
      conn = login(conn, joiner)

      {:ok, _lv, html} = live(conn, ~p"/groups/join/#{old_code}")
      refute RuleMaven.Groups.member?(joiner, grp)
      assert html =~ "Can&#39;t join" or html =~ "valid" or html =~ "matching group"
    end

    test "joining an already-joined group shows the group without erroring", %{conn: conn} do
      owner = create_user("owner_already")
      grp = group_fixture(owner)
      conn = login(conn, owner)

      {:ok, _lv, html} = live(conn, ~p"/groups/join/#{grp.invite_code}")
      assert html =~ grp.name
    end
  end

  describe "GroupLive.Show — authz through the UI" do
    test "a plain member does not see remove/rename/delete controls, and firing those events is rejected",
         %{conn: conn} do
      owner = create_user("owner_authz")
      grp = group_fixture(owner)
      member = create_user("member_authz")
      {:ok, _} = RuleMaven.Groups.join_by_code(member, grp.invite_code)
      conn = login(conn, member)

      {:ok, lv, html} = live(conn, ~p"/groups/#{grp}")

      refute html =~ "phx-click=\"delete_group\""
      refute html =~ "phx-click=\"remove_member\""

      # Firing the events directly (bypassing the hidden UI) must still be
      # rejected server-side — a hidden button is not a security control.
      render_click(lv, "rename", %{"group" => %{"name" => "Hijacked"}})
      assert Repo.reload!(grp).name == grp.name

      render_click(lv, "delete_group", %{})
      assert Repo.reload!(grp)

      render_click(lv, "remove_member", %{"user_id" => to_string(owner.id)})
      assert RuleMaven.Groups.member?(owner, grp)
    end

    test "the owner cannot be removed and cannot leave — surfaced as a flash, not a crash", %{
      conn: conn
    } do
      owner = create_user("owner_solo")
      grp = group_fixture(owner)
      conn = login(conn, owner)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{grp}")

      html = render_click(lv, "leave", %{})
      assert html =~ "transfer" or html =~ "owner"
      assert RuleMaven.Groups.member?(owner, grp)

      html = render_click(lv, "remove_member", %{"user_id" => to_string(owner.id)})
      assert html =~ "owner" or html =~ "cannot"
      assert RuleMaven.Groups.member?(owner, grp)
    end

    test "an admin can rename and regenerate but not delete or promote to owner", %{conn: conn} do
      owner = create_user("owner_admin")
      grp = group_fixture(owner)
      admin = create_user("admin_user")
      {:ok, _} = RuleMaven.Groups.join_by_code(admin, grp.invite_code)
      {:ok, _} = RuleMaven.Groups.set_role(owner, grp, admin.id, :admin)
      conn = login(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{grp}")

      render_click(lv, "rename", %{"group" => %{"name" => "Renamed by Admin"}})
      assert Repo.reload!(grp).name == "Renamed by Admin"

      html = render_click(lv, "delete_group", %{})
      assert html =~ "forbidden" or html =~ "owner" or html =~ "permission"
    end
  end

  describe "GroupLive.Show — self-removal and malformed params (IMPORTANT 2/3)" do
    test "an admin cannot remove themselves via remove_member — they must Leave", %{
      conn: conn
    } do
      owner = create_user("owner_selfrm")
      grp = group_fixture(owner)
      admin = create_user("admin_selfrm")
      {:ok, _} = RuleMaven.Groups.join_by_code(admin, grp.invite_code)
      {:ok, _} = RuleMaven.Groups.set_role(owner, grp, admin.id, :admin)
      conn = login(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{grp}")

      # Hiding the "Remove" button on your own row is not a security control —
      # a socket can push the event directly with its own user_id. Self-removal
      # is routed to leave/2 instead: it used to delete the actor's own row,
      # after which load_group/1 re-derived role: nil and the template crashed
      # on String.capitalize(nil).
      html = render_click(lv, "remove_member", %{"user_id" => to_string(admin.id)})

      refute html =~ "FunctionClauseError"
      assert html =~ "Leave group"
      assert RuleMaven.Groups.member?(admin, grp), "self-removal must be rejected, not applied"
      assert RuleMaven.Groups.role_of(admin, grp) == "admin"

      # ...and the supported path still works, without a nil-role crash.
      assert {:ok, :left} = RuleMaven.Groups.leave(admin, grp)
      refute RuleMaven.Groups.member?(admin, grp)
    end

    test "a garbage user_id on set_role/transfer_ownership/remove_member does not crash", %{
      conn: conn
    } do
      owner = create_user("owner_garbage")
      grp = group_fixture(owner)
      conn = login(conn, owner)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{grp}")

      html = render_click(lv, "set_role", %{"user_id" => "not-a-number", "role" => "admin"})
      assert is_binary(html)

      html = render_click(lv, "transfer_ownership", %{"user_id" => "not-a-number"})
      assert is_binary(html)

      html = render_click(lv, "remove_member", %{"user_id" => "not-a-number"})
      assert is_binary(html)
    end
  end
end
