defmodule RuleMaven.Auth.SignOnTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.Auth.SignOn
  alias RuleMaven.Users
  alias RuleMaven.Users.User

  @opts [group: "rulemaven-users", admin_group: "rulemaven-admins"]

  defp password_user(username \\ "carol", email \\ "carol@example.com") do
    {:ok, user} =
      Users.create_user(%{username: username, email: email, password: "correct horse 1"})

    user
  end

  test "creates on first sign-in, finds by sub afterwards" do
    claims = %{"sub" => "s1", "groups" => ["rulemaven-users"], "preferred_username" => "dan"}
    assert {:ok, %User{id: id, role: "user", username: "dan"}} = SignOn.sign_in(claims, @opts)
    assert {:ok, %User{id: ^id}} = SignOn.sign_in(claims, @opts)
  end

  test "admin group members are created as admins" do
    claims = %{"sub" => "s1", "groups" => ["rulemaven-admins"], "name" => "Erin Smith"}
    assert {:ok, %User{role: "admin", username: "Erin Smith"}} = SignOn.sign_in(claims, @opts)
  end

  describe "with a super-admin group" do
    @two @opts ++ [superadmin_group: "rulemaven-superadmins"]
    @both ["rulemaven-admins", "rulemaven-superadmins"]

    defp sign(sub, groups, opts \\ @two) do
      {:ok, user} =
        SignOn.sign_in(%{"sub" => sub, "groups" => groups, "preferred_username" => sub}, opts)

      user.role
    end

    test "follows both groups at every sign-in: super needs admin too" do
      assert sign("owner", @both) == "super_admin"
      assert sign("curator", ["rulemaven-admins"]) == "admin"
      assert sign("odd", ["rulemaven-users", "rulemaven-superadmins"]) == "user"
      assert sign("curator", @both) == "super_admin"
      assert sign("curator", ["rulemaven-admins"]) == "admin"
      assert sign("curator", ["rulemaven-users"]) == "user"
    end

    test "never demotes the last super admin who signs on (a service account doesn't count)" do
      {:ok, service} =
        Users.create_user(%{
          username: "maven",
          email: "m@example.com",
          password: "correct horse 1"
        })

      {:ok, _} = Users.set_super_admin(service, true)

      assert sign("owner", @both) == "super_admin"
      assert sign("owner", ["rulemaven-admins"]) == "super_admin"
      assert sign("second", @both) == "super_admin"
      assert sign("owner", ["rulemaven-admins"]) == "admin"
    end

    test "without one, a super admin's role stays the server's" do
      {:ok, user} = SignOn.sign_in(%{"sub" => "s1", "groups" => ["rulemaven-admins"]}, @opts)
      {:ok, _} = Users.set_super_admin(user, true)
      assert sign("s1", ["rulemaven-users"], @opts) == "super_admin"
    end
  end

  test "never matches an existing account by email or username" do
    existing = password_user()

    claims = %{
      "sub" => "s1",
      "groups" => ["rulemaven-users"],
      "preferred_username" => "Carol",
      "email" => "carol@example.com"
    }

    assert {:ok, user} = SignOn.sign_in(claims, @opts)
    assert user.id != existing.id
    assert user.username == "Carol-2"
    assert user.email == nil
  end

  test "refuses without an account id or the group" do
    assert {:error, "The sign-in service sent no account id."} =
             SignOn.sign_in(%{"groups" => ["rulemaven-users"]}, @opts)

    assert {:error, message} = SignOn.sign_in(%{"sub" => "s1", "groups" => "nope"}, @opts)
    assert message =~ "rulemaven-users"
  end

  test "a sign-on account can't be signed in with a password" do
    {:ok, user} =
      SignOn.sign_in(%{"sub" => "s1", "groups" => ["rulemaven-users"], "name" => "zed"}, @opts)

    assert {:error, _} = Users.authenticate(user.username, "")
    assert {:error, _} = Users.authenticate(user.username, "anything")
  end

  test "operator linking: link, refuse a taken sub, unlink" do
    carol = password_user()
    dave = password_user("dave", "dave@example.com")

    assert {:ok, %User{oidc_sub: "s-carol"}} = SignOn.link_user(carol, " s-carol ")

    assert {:error, "That account is already linked to a different user here."} =
             SignOn.link_user(dave, "s-carol")

    assert {:error, _} = SignOn.link_user(dave, "  ")
    assert {:ok, %User{oidc_sub: nil}} = SignOn.link_user(Users.get_user(carol.id), nil)
    assert {:ok, %User{oidc_sub: "s-carol"}} = SignOn.link_user(dave, "s-carol")
  end

  test "mix rule_maven.link_sso links by username" do
    carol = password_user()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.RuleMaven.LinkSso.run(["carol", "s-carol"])
    assert_received {:mix_shell, :info, ["Linked carol to sign-on id s-carol."]}
    assert Users.get_user(carol.id).oidc_sub == "s-carol"

    Mix.Tasks.RuleMaven.LinkSso.run(["carol", "--unlink"])
    assert Users.get_user(carol.id).oidc_sub == nil

    assert_raise Mix.Error, ~r/No user named/, fn ->
      Mix.Tasks.RuleMaven.LinkSso.run(["nobody", "s-x"])
    end
  end
end
