defmodule RuleMaven.PasswordResetTest do
  use RuleMaven.DataCase, async: true

  alias RuleMaven.Users

  defp user_fixture do
    {:ok, u} =
      Users.create_user(%{
        username: "resetme",
        email: "Reset.Me@Test.com",
        password: "oldpass1234"
      })

    u
  end

  defp token_from_email do
    {:ok, email} =
      Users.deliver_password_reset_instructions("reset.me@test.com", &("http://x/reset/" <> &1))

    [_, token] = Regex.run(~r{/reset/(\S+)}, email.text_body)
    token
  end

  test "deliver is case-insensitive and returns :ok for unknown emails" do
    user_fixture()
    assert {:ok, _email} = Users.deliver_password_reset_instructions("RESET.ME@test.com", & &1)
    assert :ok = Users.deliver_password_reset_instructions("nobody@nowhere.com", & &1)
  end

  test "full reset flow updates the password and burns the token" do
    user_fixture()
    token = token_from_email()

    assert {:ok, user} = Users.reset_password(token, "newpass5678")
    assert Bcrypt.verify_pass("newpass5678", user.password_hash)
    refute Bcrypt.verify_pass("oldpass1234", user.password_hash)

    # Token is single-use.
    assert :error = Users.reset_password(token, "another9999")
  end

  test "new password can authenticate; old cannot" do
    user_fixture()
    token = token_from_email()
    {:ok, _} = Users.reset_password(token, "newpass5678")

    assert {:ok, _} = Users.authenticate("resetme", "newpass5678")
    assert {:error, _} = Users.authenticate("resetme", "oldpass1234")
  end

  test "weak password is rejected without burning the token" do
    user_fixture()
    token = token_from_email()

    assert {:error, _changeset} = Users.reset_password(token, "no")
    # Token still valid after a rejected attempt.
    assert {:ok, _} = Users.reset_password(token, "goodpass123")
  end

  test "garbage token is rejected" do
    assert :error = Users.reset_password("not-a-token", "whatever1234")
  end
end
