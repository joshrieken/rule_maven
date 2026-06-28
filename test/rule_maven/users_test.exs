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
          role: "game_master"
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
      {:ok, updated} = Users.update_user(player, %{role: "game_master"})
      assert updated.role == "game_master"
      assert Users.game_master?(updated)
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

    test "delete_user/1 returns error for nil", %{} do
      assert {:error, :not_found} = Users.delete_user(nil)
    end

    test "update_user_role/2 is a convenience for role-only updates", %{player: player} do
      {:ok, updated} = Users.update_user_role(player, "game_master")
      assert updated.role == "game_master"
    end

    test "game_master?/1 returns true for game_master role", %{gm: gm} do
      assert Users.game_master?(gm)
    end

    test "game_master?/1 returns false for player role", %{player: player} do
      refute Users.game_master?(player)
    end

    test "can?/2 grants :admin to game_master, denies to player", %{gm: gm, player: player} do
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
          role: "game_master"
        })

      assert user.role == "game_master"
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
