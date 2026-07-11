defmodule RuleMaven.UsersSuperAdminTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.Users
  alias RuleMaven.Users.User

  defp make(role) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.create_user(%{
        username: "u#{n}",
        email: "u#{n}@example.com",
        password: "password1234",
        role: "user"
      })

    case role do
      "user" -> user
      "admin" -> elem(Users.update_user_role(user, "admin"), 1)
      "super_admin" -> elem(Users.set_super_admin(user, true), 1)
    end
  end

  describe "capabilities" do
    test "super_admin holds :admin and :superadmin; admin holds neither superadmin" do
      assert Users.can?(make("super_admin"), :admin)
      assert Users.can?(make("super_admin"), :superadmin)

      admin = make("admin")
      assert Users.can?(admin, :admin)
      refute Users.can?(admin, :superadmin)

      refute Users.can?(make("user"), :admin)
    end

    test "roles_with_capability(:admin) includes super_admin" do
      assert "super_admin" in User.roles_with_capability(:admin)
    end

    test "assignable roles exclude super_admin" do
      refute "super_admin" in Users.roles()
    end
  end

  describe "the web layer cannot mint a super admin" do
    test "create_user rejects a forged super_admin role" do
      n = System.unique_integer([:positive])

      assert {:error, changeset} =
               Users.create_user(%{
                 username: "x#{n}",
                 email: "x#{n}@example.com",
                 password: "password1234",
                 role: "super_admin"
               })

      assert %{role: [_ | _]} = errors_on(changeset)
    end

    test "update_user_role rejects promoting anyone to super_admin" do
      assert {:error, changeset} = Users.update_user_role(make("admin"), "super_admin")
      assert %{role: [_ | _]} = errors_on(changeset)
    end

    test "set_super_admin (mix-task path) does grant it" do
      user = make("user")
      assert {:ok, updated} = Users.set_super_admin(user, true)
      assert Users.super_admin?(updated)
      assert {:ok, back} = Users.set_super_admin(updated, false)
      refute Users.super_admin?(back)
    end
  end

  describe "a super admin is immune to admin action" do
    setup do: %{sa: make("super_admin")}

    test "role can't be changed", %{sa: sa} do
      assert {:error, :super_admin} = Users.update_user_role(sa, "user")
      assert {:error, :super_admin} = Users.demote_admin(sa)
      assert Users.super_admin?(Users.get_user(sa.id))
    end

    test "can't be suspended, logged out, zeroed, throttled or deleted", %{sa: sa} do
      assert {:error, :super_admin} = Users.suspend_user(sa)
      assert {:error, :super_admin} = Users.force_logout(sa)
      assert {:error, :super_admin} = Users.reset_reputation(sa)
      assert {:error, :super_admin} = Users.set_quota(sa, 0)
      assert {:error, :super_admin} = Users.delete_user(sa)

      reloaded = Users.get_user(sa.id)
      refute Users.suspended?(reloaded)
      assert reloaded.sessions_valid_after == nil
    end

    test "an ordinary admin is still moderatable" do
      admin = make("admin")
      assert {:ok, _} = Users.force_logout(admin)
      assert {:ok, _} = Users.reset_reputation(admin)
    end
  end

  describe "demote_admin last-admin check counts super admins" do
    test "the sole ordinary admin can be demoted while a super admin exists" do
      _sa = make("super_admin")
      admin = make("admin")
      assert {:ok, demoted} = Users.demote_admin(admin)
      refute Users.can?(demoted, :admin)
    end
  end
end
