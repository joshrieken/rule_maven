defmodule RuleMaven.UsersTest do
  use RuleMaven.DataCase

  alias RuleMaven.Users
  alias RuleMaven.Users.User
  alias RuleMaven.Repo

  describe "user management" do
    setup do
      {:ok, player} =
        Users.create_user(%{
          username: "player1",
          email: "player1@test.com",
          password: "testpass1234"
        })

      {:ok, gm} =
        Users.create_user(%{
          username: "gm1",
          email: "gm1@test.com",
          password: "testpass1234",
          role: "admin"
        })

      %{player: player, gm: gm}
    end

    test "email confirmation: deliver, confirm, and idempotency", %{player: player} do
      refute Users.email_confirmed?(player)

      # The notifier returns the built email; pull the token straight out of it.
      {:ok, email} =
        Users.deliver_user_confirmation_instructions(player, fn t -> "http://x/confirm/" <> t end)

      [_, token] = Regex.run(~r{/confirm/(\S+)}, email.text_body)

      assert {:ok, confirmed} = Users.confirm_user(token)
      assert Users.email_confirmed?(confirmed)
      # Token is burned — second use fails.
      assert :error = Users.confirm_user(token)
    end

    test "deliver is a no-op once already confirmed", %{player: player} do
      {:ok, confirmed} = player |> User.confirm_changeset() |> Repo.update()

      assert {:error, :already_confirmed} =
               Users.deliver_user_confirmation_instructions(confirmed, fn t -> t end)
    end

    test "confirm_user/1 rejects a garbage token" do
      assert :error = Users.confirm_user("not-a-real-token")
    end

    test "list_users/0 returns all users", %{player: player, gm: gm} do
      users = Users.list_users()
      ids = Enum.map(users, & &1.id)
      assert player.id in ids
      assert gm.id in ids
    end

    test "update_user/2 changes role", %{player: player} do
      {:ok, updated} = Users.update_user(player, %{role: "admin"})
      assert updated.role == "admin"
      assert Users.admin?(updated)
    end

    test "update_user/2 rejects invalid role", %{player: player} do
      {:error, changeset} = Users.update_user(player, %{role: "super_admin"})
      assert changeset.errors[:role]
    end

    test "update_user/2 rejects duplicate username", %{player: player, gm: gm} do
      {:error, changeset} = Users.update_user(player, %{username: gm.username})
      assert changeset.errors[:username]
    end

    test "delete_user/1 removes the user", %{player: player} do
      {:ok, _} = Users.delete_user(player)
      assert Repo.get(User, player.id) == nil
    end

    test "suspended account cannot authenticate, lift restores login", %{player: player} do
      assert {:ok, _} = Users.authenticate(player.username, "testpass1234")

      {:ok, suspended} = Users.suspend_user(player)
      assert Users.suspended?(suspended)
      assert {:error, msg} = Users.authenticate(player.username, "testpass1234")
      assert msg =~ "suspended"

      {:ok, restored} = Users.unsuspend_user(suspended)
      refute Users.suspended?(restored)
      assert {:ok, _} = Users.authenticate(player.username, "testpass1234")
    end

    test "wrong password still beats suspension check", %{player: player} do
      {:ok, _} = Users.suspend_user(player)
      assert {:error, msg} = Users.authenticate(player.username, "wrongpass")
      assert msg =~ "Invalid"
    end

    test "reset_reputation/1 zeroes reputation", %{player: player} do
      {:ok, bumped} = Users.update_user(player, %{})
      Repo.update_all(from(u in User, where: u.id == ^bumped.id), set: [reputation: 42])
      {:ok, reset} = Users.reset_reputation(Repo.reload(bumped))
      assert reset.reputation == 0
    end

    test "delete_user/1 returns error for nil", %{} do
      assert {:error, :not_found} = Users.delete_user(nil)
    end

    test "update_user_role/2 is a convenience for role-only updates", %{player: player} do
      {:ok, updated} = Users.update_user_role(player, "admin")
      assert updated.role == "admin"
    end

    test "admin?/1 returns true for admin role", %{gm: gm} do
      assert Users.admin?(gm)
    end

    test "admin?/1 returns false for player role", %{player: player} do
      refute Users.admin?(player)
    end

    test "can?/2 grants :admin to admin, denies to player", %{gm: gm, player: player} do
      assert Users.can?(gm, :admin)
      refute Users.can?(player, :admin)
    end

    test "can?/2 denies unknown capabilities and nil users", %{gm: gm} do
      refute Users.can?(gm, :nonexistent)
      refute Users.can?(nil, :admin)
    end
  end

  describe "create user with temp password" do
    test "creates user with auto-generated temp password" do
      {:ok, user, password} =
        Users.create_user_with_temp_password(%{
          username: "new_player",
          email: "new@test.com"
        })

      assert user.username == "new_player"
      assert user.email == "new@test.com"
      assert user.role == "player"
      assert String.length(password) >= 8
    end

    test "creates user with specified role" do
      {:ok, user, _password} =
        Users.create_user_with_temp_password(%{
          username: "new_gm",
          email: "new_gm@test.com",
          role: "admin"
        })

      assert user.role == "admin"
    end

    test "generated password is usable for login" do
      {:ok, _user, password} =
        Users.create_user_with_temp_password(%{
          username: "login_test",
          email: "login_test@test.com"
        })

      {:ok, authenticated} = Users.authenticate("login_test", password)
      assert authenticated.username == "login_test"
    end

    test "returns error for missing username" do
      {:error, changeset, _password} =
        Users.create_user_with_temp_password(%{
          email: "no_user@test.com"
        })

      assert changeset.errors[:username]
    end

    test "returns error for missing email" do
      {:error, changeset, _password} =
        Users.create_user_with_temp_password(%{
          username: "no_email"
        })

      assert changeset.errors[:email]
    end

    test "returns error for duplicate username" do
      {:ok, existing, _} =
        Users.create_user_with_temp_password(%{
          username: "duplicate_me",
          email: "dup_existing@test.com"
        })

      {:error, changeset, _password} =
        Users.create_user_with_temp_password(%{
          username: existing.username,
          email: "dup_new@test.com"
        })

      assert changeset.errors[:username]
    end

    test "generated passwords are unique" do
      {:ok, _, pw1} =
        Users.create_user_with_temp_password(%{
          username: "unique1",
          email: "u1@test.com"
        })

      {:ok, _, pw2} =
        Users.create_user_with_temp_password(%{
          username: "unique2",
          email: "u2@test.com"
        })

      assert pw1 != pw2
    end
  end

  describe "profile update" do
    setup do
      {:ok, user} =
        Users.create_user(%{
          username: "profile_test",
          email: "profile@test.com",
          password: "testpass1234"
        })

      %{user: user}
    end

    test "update_profile/2 changes username and email", %{user: user} do
      {:ok, updated} = Users.update_profile(user, %{username: "new_name", email: "new@test.com"})
      assert updated.username == "new_name"
      assert updated.email == "new@test.com"
    end

    test "update_profile/2 rejects duplicate username", %{user: user} do
      {:ok, other} =
        Users.create_user(%{
          username: "other_user",
          email: "other@test.com",
          password: "testpass1234"
        })

      {:error, changeset} = Users.update_profile(user, %{username: other.username})
      assert changeset.errors[:username]
    end

    test "update_profile/2 rejects invalid email", %{user: user} do
      {:error, changeset} = Users.update_profile(user, %{email: ""})
      assert changeset.errors[:email]
    end

    test "change_password/3 succeeds with correct current password", %{user: user} do
      {:ok, updated} = Users.change_password(user, "testpass1234", "newpass5678")
      assert updated

      {:ok, authed} = Users.authenticate("profile_test", "newpass5678")
      assert authed.id == user.id
    end

    test "change_password/3 fails with wrong current password", %{user: user} do
      {:error, reason} = Users.change_password(user, "wrongpassword", "newpass5678")
      assert reason =~ "incorrect"
    end

    test "change_password/3 fails with too-short new password", %{user: user} do
      {:error, reason} = Users.change_password(user, "testpass1234", "ab")
      assert reason =~ "4 characters"
    end
  end
end
